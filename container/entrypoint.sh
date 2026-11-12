#!/bin/bash
# Container main process: start the chain and fabric node (once they've been set up) and stay alive.
# On `podman stop`, shut both down cleanly first - the dev chain only saves its state on a clean shutdown.

wait_until_stopped() {
  for _ in $(seq 30); do pgrep -x "$1" > /dev/null || return; sleep 1; done
}

shutdown() {
  echo "stopping qfab and elvmasterd"
  pkill -x qfab;       wait_until_stopped qfab
  pkill -x elvmasterd; wait_until_stopped elvmasterd
  exit 0
}
trap shutdown TERM INT

mkdir -p /data/logs
/opt/qfab-dev/daemons.sh

sleep infinity &
wait    # returns when a signal arrives, which runs shutdown
