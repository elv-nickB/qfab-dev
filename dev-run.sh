#!/bin/bash
# Build and run a local, self-contained content fabric (chain + qfab node + tenant + live stream) in podman.
#   1. build qfab and qfab_cli from the code in $QFAB_REPO (build-qfab.sh)
#   2. build the qfab-dev image (Containerfile), which copies those binaries in
#   3. start the container (start.sh)
#   4. first run only: set up chain, space, node, tenant and live stream (container/setup.sh)
#
# State lives in the podman volume qfab-dev-data and survives rebuilds. Remove it to start from scratch:
#   podman rm -f qfab-dev && podman volume rm qfab-dev-data
set -euo pipefail

# QFAB_REPO: the content-fabric checkout to build and run (required)
REPO=$(cd "${QFAB_REPO:?set QFAB_REPO to your content-fabric checkout}" && pwd)
cd "$(dirname "$0")"
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}   # GitHub key for the private qluvio repos

echo "== 1. build qfab and qfab_cli"
./build-qfab.sh build
# build-devsetup.sh reads ../config/dev-config.json relative to itself - keep the repo layout
mkdir -p build/devsetup/scripts build/devsetup/config
cp "$REPO/scripts/build-devsetup.sh" build/devsetup/scripts/
cp "$REPO/config/dev-config.json" build/devsetup/config/

echo "== 2. build the qfab-dev image"
podman build --ssh default="$SSH_KEY" -t qfab-dev .

echo "== 3. start the container"
./start.sh

echo "== 4. set up the fabric (skips whatever is already done)"
podman exec qfab-dev /opt/qfab-dev/setup.sh
