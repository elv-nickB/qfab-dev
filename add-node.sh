#!/bin/bash
# Add a second qfab node, built from the code in $QFAB_REPO, to the fabric started by dev-run.sh.
#   1. build qfab and qfab_cli from the code in $QFAB_REPO into build-node2/ (build-qfab.sh)
#   2. build an image with those binaries: qfab-dev:node2
#   3. first run only: register the node in the space and write its config (container/setup-node.sh)
#   4. (re)start it as the container qfab-node2 - API: http://127.0.0.1:8009
#
# Typical use: run dev-run.sh on one branch, then check out another (or point QFAB_REPO elsewhere) and run this. Both nodes then serve the same content.
# It shares the qfab-dev-data volume (its data is in /data/nodes/node2) and the chain running in qfab-dev.
set -euo pipefail

cd "$(dirname "$0")"
NAME=node2
PORT=8009
CONTAINER=qfab-$NAME
IMAGE=qfab-dev:$NAME
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}

if ! podman container exists qfab-dev; then
  echo "qfab-dev isn't running - run dev-run.sh first" >&2
  exit 1
fi

echo "== 1. build qfab and qfab_cli"
./build-qfab.sh build-$NAME

echo "== 2. build the $IMAGE image"
podman build --ssh default="$SSH_KEY" --build-arg BIN_DIR=build-$NAME -t $IMAGE .

# Same as qfab-dev: host network, the shared data volume, and time for a clean shutdown
run_args=(--init --network host --stop-timeout 60 -v qfab-dev-data:/data)

echo "== 3. set up the node (skipped if already done)"
podman run --rm "${run_args[@]}" --entrypoint /opt/qfab-dev/setup-node.sh $IMAGE $NAME $PORT

echo "== 4. start $CONTAINER"
if podman container exists $CONTAINER; then
  podman stop --time 60 $CONTAINER > /dev/null
  podman rm $CONTAINER > /dev/null
fi
podman run -d --name $CONTAINER "${run_args[@]}" \
  --entrypoint qfab $IMAGE daemon --config /data/nodes/$NAME/qfab.json > /dev/null

echo -n "waiting for http://127.0.0.1:$PORT"
until curl -s -m 2 -o /dev/null http://127.0.0.1:$PORT; do
  if [ "$(podman inspect -f '{{.State.Running}}' $CONTAINER)" != true ]; then
    echo " $CONTAINER exited - see: podman logs $CONTAINER" >&2
    exit 1
  fi
  echo -n .; sleep 1
done
echo " up"
curl -s "http://127.0.0.1:$PORT/config?qspace=dev&self" | jq '{node_id, fabric_version}'
