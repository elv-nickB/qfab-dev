#!/bin/bash
# One-time setup of an extra fabric node (see add-node.sh). Runs in the new node's container, which shares the
# /data volume with qfab-dev - that's where the space owner's CLI config, the chain's keystore and node 1's config are.
#   1. register the node in the content space, at its own API port
#   2. write its qfab.json: node 1's config with this node's id, wallet, port and data folder
# usage: setup-node.sh NAME PORT
set -euo pipefail

NAME=$1
PORT=$2
DIR=/data/nodes/$NAME
DEVSETUP=/opt/qfab-dev/devsetup/scripts/build-devsetup.sh

if [ -s $DIR/qfab.json ]; then echo "$NAME: already set up"; exit 0; fi
mkdir -p $DIR/QDATA

# The node's identity: a funded account that the dev chain creates in its keystore (the "Node2" key the
# integration tests use for their second node). Node ids are the account address in fabric format.
ACCOUNT=4163a41b433cbf55c5836376c417f676bd4e0de0
NODE_ID=$(qfab tools id format 0x$ACCOUNT -t node)
WALLET=$(ls /data/RUN/elv-master/keystore/*--$ACCOUNT)

# 1. Register it in the content space - as the space owner, like build-devsetup.sh does for node 1
KMS_ID=$(sed -n 's/^kms_id="\(.*\)"$/\1/p' $DEVSETUP)
echo "registering $NAME ($NODE_ID) at http://127.0.0.1:$PORT"
qfab_cli space node add $NODE_ID fab+http://127.0.0.1:$PORT eth+http://127.0.0.1:8545 \
  --config /data/RUN/config/qfab_cli_space_owner.json --kms $KMS_ID

# 2. Its config: start from node 1's and change what must differ
#   - identity:  node id and wallet
#   - network:   API port, and the WASM bitcode port range (both containers share the host's ports)
#   - storage:   every node 1 data path (/data/RUN/QDATA, also written as ./RUN/QDATA) moves to $DIR/QDATA
jq --arg node_id "$NODE_ID" --arg wallet "$WALLET" --arg url "http://127.0.0.1:$PORT" \
   --arg qdata "$DIR/QDATA" --arg dir "$DIR" '
     .fabric.node_id = $node_id
   | .qspaces[0].ethereum.wallet_file = $wallet
   | .api.base_url = $url
   | .wapc.port_range = "7201:7300"
   | .log.file.filename = ($dir + "/qfab.log")
   | .paths.config_path = $dir
   | walk(if type == "string" then gsub("^(/data|\\.)/RUN/QDATA"; $qdata) else . end)
  ' /data/RUN/config/qfab.json > $DIR/qfab.json

echo "$NAME set up: $DIR/qfab.json"
