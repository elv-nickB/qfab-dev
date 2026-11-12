#!/bin/bash
# One-time setup of the local fabric. dev-run.sh runs this inside the container.
#
# Steps (see main at the bottom):
#   1. chain, content space, KMS and fabric node  - the repo's scripts/build-devsetup.sh
#   2. tenant: admin account, groups, contract    - elv-admin space_tenant_create
#   3. tenant libraries and content types         - elv-live tenant_provision
#   4. live stream object                         - elv-stream create
#   5. its recording config (probes a test input) - elv-stream config
#   6. start recording: listens on the SRT port   - elv-stream start_recording
#
# Every step saves what it produced under /data and is skipped when that already exists,
# so after a failure you can fix the problem and simply run this again.

set -euo pipefail   # stop at the first failing command

DEVSETUP=/opt/qfab-dev/devsetup/scripts/build-devsetup.sh
PROFILE=/opt/qfab-dev/live-profile.json
LOGS=/data/logs
STATE=/data/state               # one small file per value we keep (tenant id, keys, ...)
STREAM_URL="srt://127.0.0.1:11080?mode=listener"


# ---------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------

# save NAME VALUE / load NAME: keep a value in $STATE/NAME
save() { echo "$2" > "$STATE/$1"; }
load() { cat "$STATE/$1"; }
have() { [ -s "$STATE/$1" ]; }

# yaml_value FILE KEY: the value of the last "KEY: value" line in FILE, without quotes.
# (The commands print their result as YAML at the very end, after any debug output.)
yaml_value() { grep "^ *$2: " "$1" | tail -1 | sed "s/^ *$2: //" | tr -d "'\""; }

# run_elv LOG COMMAND...: run an elv-live-js command, show and log its output.
# Those commands print "ERROR: ..." on failure but still exit successfully, so check for that ourselves.
run_elv() {
  local log=$LOGS/$1; shift
  "$@" 2>&1 | tee "$log"
  if grep -q '^ERROR:' "$log"; then
    echo "FAILED: $* - see $log" >&2
    exit 1
  fi
}

# A test pattern pushed over SRT, retried until something listens on the port.
# `elv-stream config` builds the stream's recording settings (frame rate, keyframe interval) from what it probes
# here, so whatever you stream later must match: 25 fps, a keyframe every 2 seconds (50 frames).
# (23.976 fps isn't an option: elv-client-js has no MPEG-TS settings for it - convert such sources with -vf fps=25.)
start_test_source() {
  (while true; do
     ffmpeg -loglevel error -re -f lavfi -i testsrc2=size=1280x720:rate=25 -f lavfi -i sine=sample_rate=48000 \
       -c:v libx264 -g 50 -pix_fmt yuv420p -c:a aac -f mpegts "srt://127.0.0.1:11080" || sleep 1
   done) > $LOGS/test-source.log 2>&1 &
  TEST_SOURCE_PID=$!
}
stop_test_source() {
  kill $TEST_SOURCE_PID 2>/dev/null || true
  pkill -f 'lavfi -i testsrc2' || true
}


# ---------------------------------------------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------------------------------------------

setup_chain_and_node() {
  # Done once the node's config exists. A half-finished earlier attempt is wiped and redone.
  if [ -s /data/RUN/config/qfab.json ]; then echo "1. chain and node: already set up"; return; fi
  echo "1. chain, content space, KMS and node"

  pkill -x qfab || true
  pkill -x elvmasterd || true
  rm -rf /data/RUN

  $DEVSETUP "$(command -v elvmasterd)" "$(command -v qfab)" "$(command -v qfab_cli)" --dir /data/RUN \
    > $LOGS/devsetup.log 2>&1

  # It stops its chain and node as it exits - wait until they're really gone, so daemons.sh starts new ones
  while pgrep -x qfab > /dev/null || pgrep -x elvmasterd > /dev/null; do sleep 1; done

  if [ ! -s /data/RUN/config/qfab.json ]; then
    echo "FAILED: build-devsetup.sh - see $LOGS/devsetup.log" >&2
    exit 1
  fi

  # Refresh the list of space nodes every 10s instead of every 5 minutes, so nodes added with add-node.sh are
  # recognized quickly (a node only serves parts to nodes it knows about)
  local config=/data/RUN/config/qfab.json
  jq '.fabric.config_update_period = "10s"' $config > $config.new && mv $config.new $config
}

create_tenant() {
  if have tenant_id; then echo "2. tenant: already created"; return; fi
  echo "2. tenant"

  # The space owner creates the tenant. Its key is a fixed dev key defined in build-devsetup.sh.
  local space_owner_key
  space_owner_key=$(sed -n 's/^space_owner_private_key="\(.*\)"$/\1/p' $DEVSETUP)

  PRIVATE_KEY=$space_owner_key run_elv tenant-create.log \
    elv-admin space_tenant_create dev-tenant --funds 200

  # From the YAML it prints: the new tenant admin account's key, and the tenant (contract) id
  save tenant_key "$(yaml_value $LOGS/tenant-create.log privateKey)"
  save tenant_id  "$(yaml_value $LOGS/tenant-create.log tenantContractId)"
}

provision_tenant() {
  if have library_id; then echo "3. tenant libraries and types: already provisioned"; return; fi
  echo "3. tenant libraries and content types"

  # tenant_provision records its progress in tenant_status.json and resumes from it if re-run
  cd /data/state

  if [ ! -f tenant_status.json ]; then
    # Get its default settings and switch off the parts that need Eluvio's hosted services:
    # publishing the tenant's public site, the funding faucet and the share signer.
    PRIVATE_KEY=$(load tenant_key) run_elv provision-init.log \
      elv-live tenant_provision "$(load tenant_id)" dev-tenant --init_config

    sed -n '/^{/,$p' $LOGS/provision-init.log \
      | jq 'del(.base.publish) | .base.faucet.enable = false | .base.shareSigner.enable = false' \
      > tenant_status.json
  fi

  PRIVATE_KEY=$(load tenant_key) run_elv provision.log \
    elv-live tenant_provision "$(load tenant_id)" dev-tenant --status tenant_status.json

  # The library we'll put the live stream in
  save library_id "$(jq -r .base.libraries.mezzanineLibraryId tenant_status.json)"
  cd /data
}

create_stream() {
  if have stream_id; then echo "4. live stream object: already created"; return; fi
  echo "4. live stream object"

  # The content object, with our recording profile and the SRT URL to listen on
  PRIVATE_KEY=$(load tenant_key) run_elv stream-create.log \
    elv-stream create --library "$(load library_id)" --stream_url "$STREAM_URL" \
      --live_recording_config $PROFILE --name "dev stream"

  save stream_id "$(yaml_value $LOGS/stream-create.log objectId)"
}

configure_stream() {
  if have stream_configured; then echo "5. stream config: already done"; return; fi
  echo "5. stream config"

  # `config` probes the input to work out the recording settings, so it needs a live source meanwhile
  start_test_source
  PRIVATE_KEY=$(load tenant_key) run_elv stream-config.log elv-stream config "$(load stream_id)"
  stop_test_source

  save stream_configured yes
}

start_stream() {
  if have stream_started; then echo "6. stream recording: already started"; return; fi
  echo "6. stream recording"

  # Open a new recording and start it: the node now listens for your stream on the SRT port
  PRIVATE_KEY=$(load tenant_key) run_elv stream-start.log \
    elv-stream start_recording "$(load stream_id)" --start

  save stream_started yes
}

write_summary() {
  jq -n \
    --arg tenant_id   "$(load tenant_id)" \
    --arg tenant_key  "$(load tenant_key)" \
    --arg library_id  "$(load library_id)" \
    --arg stream_id   "$(load stream_id)" \
    '{
       fabric_url:         "http://127.0.0.1:8008",
       config_url:         "http://127.0.0.1:8008/config?qspace=dev&self",
       tenant_id:          $tenant_id,
       tenant_private_key: $tenant_key,
       library_id:         $library_id,
       stream_id:          $stream_id,
       srt_ingest:         "srt://127.0.0.1:11080"
     }' | tee /data/dev.json
}


# ---------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------

main() {
  mkdir -p $LOGS $STATE
  cd /data

  setup_chain_and_node
  /opt/qfab-dev/daemons.sh      # build-devsetup.sh stops its chain and node when it exits - start them again
  create_tenant
  provision_tenant
  create_stream
  configure_stream
  start_stream
  write_summary
}

main
