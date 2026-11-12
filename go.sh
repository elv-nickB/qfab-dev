#!/bin/bash
# Run a go command on this repo inside the CI build image, which has the native libraries the code
# needs (ffmpeg with SRT, AMCL) - same setup as build-qfab.sh. Run from anywhere; paths are relative
# to the repo root.
#
# examples:
#   ./go.sh test -tags "avpipe WAPC" ./extapi/avtest/ -run TestLiveVertical -v
#   ./go.sh vet  -tags "avpipe WAPC" ./extapi/avtest/
set -euo pipefail

# QFAB_REPO: the content-fabric checkout to build and run (required)
REPO=$(cd "${QFAB_REPO:?set QFAB_REPO to your content-fabric checkout}" && pwd)
cd "$(dirname "$0")"
BASE_IMAGE=us-docker.pkg.dev/github-qluvio/builders/u22-cpu-release:2026-06-10-83259
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519}   # GitHub key for the private qluvio Go modules

# -t only when we have a terminal, so the output keeps its colours but piping still works
TTY=""; [ -t 1 ] && TTY="-t"

podman run --rm -i $TTY \
  -v "$REPO:/src" -w /src \
  -v qfab-dev-gocache:/root/.cache -e GOMODCACHE=/root/.cache/gomod \
  -v "$SSH_KEY:/run/ssh-key:ro" \
  -e GIT_SSH_COMMAND="ssh -F /dev/null -i /run/ssh-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null" \
  -e GOPRIVATE="github.com/qluvio/*" -e GOFLAGS=-buildvcs=false \
  --entrypoint go $BASE_IMAGE "$@"
