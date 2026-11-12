#!/bin/bash
# Control the dev fabric's live stream (the one setup.sh created).
#
# usage: ./stream.sh COMMAND
#   status     state of the stream and its current recording (edge write token)
#   stop       stop recording - frees the SRT port; the recording and its periods are kept
#   start      start recording again in the same recording - a new period
#   reset      stop + start: a new period in the same recording (so a new data stream can be opened)
#   terminate  DELETE the recording (its edge write token and all its periods) - the stream goes inactive
#   new        terminate, then begin a brand new recording
set -euo pipefail

# Run an elv-stream command in the container, as the tenant admin, on our stream.
# (elv-stream prints "ERROR: ..." on failure but still exits successfully, so check for that.)
elv_stream() {
  local output
  output=$(podman exec qfab-dev bash -c \
    'PRIVATE_KEY=$(cat /data/state/tenant_key) elv-stream "$@" $(cat /data/state/stream_id)' -- "$@" 2>&1)
  echo "$output"
  if grep -q '^ERROR:' <<< "$output"; then
    echo "FAILED: elv-stream $*" >&2
    exit 1
  fi
}

case "${1:-}" in
  status)    elv_stream status ;;
  stop)      elv_stream stop ;;
  start)     elv_stream start ;;
  reset)     elv_stream reset ;;
  terminate) elv_stream terminate ;;
  new)
    elv_stream terminate
    elv_stream start_recording --start
    ;;
  *)
    sed -n '4,10p' "$0"   # print the usage above
    exit 1
    ;;
esac
