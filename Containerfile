# Local content fabric dev image.
# Built by dev-run.sh - see there for the build-context layout (build/ holds the qfab binaries).

# Eluvio's CI build image: Go, ffmpeg with SRT, AMCL, ... (made from qluvio/elv-toolchain)
FROM us-docker.pkg.dev/github-qluvio/builders/u22-cpu-release:2026-06-10-83259

# lsof: port check in scripts/build-devsetup.sh
RUN apt-get update && apt-get install -y lsof

# Node.js + elv-live-js (elv-admin, elv-live, elv-stream)
RUN curl -fsSL https://nodejs.org/dist/v20.18.1/node-v20.18.1-linux-x64.tar.xz \
    | tar -xJ -C /usr/local --strip-components=1

# GIT_CONFIG_GLOBAL: skip the base image's https -> ssh rewrite (no deploy key here; the repo is public)
RUN export GIT_CONFIG_GLOBAL=/dev/null \
 && git clone https://github.com/eluv-io/elv-live-js.git /opt/elv-live-js \
 && cd /opt/elv-live-js && npm install

# elvmasterd + elvmastercli from the private elv-master repo. The SSH key comes from `podman build --ssh`;
# GIT_SSH_COMMAND ignores the base image's ssh config so that key is used for the clone and private Go modules.
RUN --mount=type=ssh \
    export GIT_SSH_COMMAND="ssh -F /dev/null -o StrictHostKeyChecking=accept-new" GOPRIVATE="github.com/qluvio/*" \
 && git clone --depth 1 git@github.com:qluvio/elv-master.git /tmp/elv-master \
 && cd /tmp/elv-master \
 && go generate ./version ./authority \
 && GOBIN=/usr/local/bin go install ./cmd/elvmasterd ./cmd/elvmastercli \
 && cd / && rm -rf /tmp/elv-master /root/go/pkg/mod /root/.cache/go-build

ENV PATH=/opt/elv-live-js:$PATH \
    ELV_NET=dev \
    ELV_WALLET_PASSPHRASE=test

# Setup scripts, then the locally built qfab binaries (last: they change most often).
# BIN_DIR: where build-qfab.sh put them - add-node.sh uses its own so the two nodes can run different versions.
ARG BIN_DIR=build
COPY container/ /opt/qfab-dev/
COPY build/devsetup/ /opt/qfab-dev/devsetup/
COPY ${BIN_DIR}/qfab ${BIN_DIR}/qfab_cli /usr/local/bin/

WORKDIR /data
ENTRYPOINT ["/opt/qfab-dev/entrypoint.sh"]
