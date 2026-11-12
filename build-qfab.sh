#!/bin/bash
# Build qfab and qfab_cli from the code in $QFAB_REPO into the given directory (default: build).
# Runs inside the CI build image, which has the native libraries qfab needs (ffmpeg with SRT, AMCL).
# Used by dev-run.sh and add-node.sh.
set -euo pipefail

# QFAB_REPO: the content-fabric checkout to build and run (required)
REPO=$(cd "${QFAB_REPO:?set QFAB_REPO to your content-fabric checkout}" && pwd)
cd "$(dirname "$0")"
OUT=${1:-build}
BASE_IMAGE=us-docker.pkg.dev/github-qluvio/builders/u22-cpu-release:2026-06-10-83259
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}   # GitHub key for the private qluvio Go modules

# The registry login saved by `gcloud auth configure-docker` expires - use a fresh token
if ! podman image exists $BASE_IMAGE; then
  podman pull --creds "oauth2accesstoken:$(gcloud auth print-access-token)" $BASE_IMAGE
fi

# The repo is mounted at /src. qfab-dev-gocache keeps Go modules and the build cache between runs.
# `go generate ./version` refreshes version/version-info.go (git-ignored) with the current branch and commit.
mkdir -p "$OUT"
podman run --rm \
  -v "$REPO:/src" -w /src \
  -v "$PWD/$OUT:/out" \
  -v qfab-dev-gocache:/root/.cache -e GOMODCACHE=/root/.cache/gomod \
  -v "$SSH_KEY:/run/ssh-key:ro" \
  -e GIT_SSH_COMMAND="ssh -F /dev/null -i /run/ssh-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null" \
  -e GOPRIVATE="github.com/qluvio/*" -e GOFLAGS=-buildvcs=false \
  --entrypoint bash $BASE_IMAGE -c '
    set -e
    go generate ./version
    go build -tags "avpipe WAPC" -o /out/qfab ./qfab
    go build -o /out/qfab_cli ./client/qfab_cli'

echo "built $OUT/qfab and $OUT/qfab_cli from $(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
