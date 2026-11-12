#!/bin/bash
# (Re)start the qfab-dev container from the current image. Its entrypoint brings up the chain and qfab node.
#   fabric API: http://127.0.0.1:8008    chain: http://127.0.0.1:8545    SRT ingest: 127.0.0.1:11080
set -euo pipefail

# Stop the running container first, giving it time to shut the chain down cleanly (it loses its state otherwise)
if podman container exists qfab-dev; then
  echo "stopping the current qfab-dev container"
  podman stop --time 60 qfab-dev > /dev/null
  podman rm qfab-dev > /dev/null
fi

# The container uses the host's ports. If one is still taken - e.g. by daemons left over from a container that
# podman lost track of - this container would silently not start its own, so stop here instead.
for port in 8545 8008; do
  if ss -ltn "sport = :$port" | grep -q LISTEN; then
    echo "port $port is already in use:" >&2
    ss -ltnp "sport = :$port" >&2
    exit 1
  fi
done

# --network host: the container's ports are the host's ports (all bound to 127.0.0.1)
# --init:         a tiny init process that forwards `podman stop` to the entrypoint and reaps exited processes
podman run -d --init --name qfab-dev --network host --stop-timeout 60 \
  -v qfab-dev-data:/data \
  qfab-dev > /dev/null

if ! podman exec qfab-dev test -s /data/RUN/config/qfab.json; then
  echo "qfab-dev started - not set up yet (dev-run.sh does that)"
  exit 0
fi

echo -n "waiting for the fabric API"
until curl -s -m 2 -o /dev/null http://127.0.0.1:8008; do echo -n .; sleep 1; done
echo " up"
podman exec qfab-dev cat /data/dev.json 2>/dev/null || true

# A restart ends the live recording. Start it again with:
#   podman exec qfab-dev bash -c 'PRIVATE_KEY=$(cat /data/state/tenant_key) elv-stream start $(cat /data/state/stream_id)'
