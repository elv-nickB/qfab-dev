#!/bin/bash
# Start elvmasterd (chain) and qfab (fabric node) in the background, unless they already run in this container.
# Does nothing until setup.sh has created their config under /data/RUN.
set -euo pipefail

RUN=/data/RUN
CHAIN=http://127.0.0.1:8545
FABRIC=http://127.0.0.1:8008

if [ ! -s $RUN/config/qfab.json ]; then
  echo "fabric not set up yet - run setup.sh"
  exit 0
fi

up() { curl -s -m 2 -o /dev/null "$1"; }
running() { pgrep -x "$1" > /dev/null; }   # is the process running in this container?

wait_up() {
  for _ in $(seq 60); do up "$1" && return; sleep 1; done
  echo "timed out waiting for $1" >&2
  return 1
}

cd $RUN

# Check for our own processes, not the ports: the ports are shared with the host (--network host), so a port
# that answers could belong to something else - start.sh refuses to start if it does.
if ! running elvmasterd; then
  echo "starting elvmasterd"
  # --gcmode archive: write every block's state to disk as it's made. The default keeps it in memory until a
  # clean shutdown, so any hard kill (podman rm -f, a crash, a reboot) would roll the chain back to genesis.
  setsid elvmasterd start dev --gcmode archive --config=$RUN/config/elvmasterd_dev_config.toml \
    >> /data/logs/elvmasterd.log 2>&1 < /dev/null &
  wait_up $CHAIN
fi

if ! running qfab; then
  echo "starting qfab"
  setsid qfab daemon --config $RUN/config/qfab.json >> /data/logs/qfab.log 2>&1 < /dev/null &
  wait_up $FABRIC
fi
