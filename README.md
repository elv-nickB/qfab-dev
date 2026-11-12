# qfab-dev

A self contained qfab and elvmastercli instance running in podman - nothing is installed on the host.

## Requirements

- podman
- `gcloud` logged in with access to the Eluvio CI build image (`us-docker.pkg.dev/github-qluvio/builders`)
- an SSH key with access to the private qluvio GitHub repos - `~/.ssh/id_ed25519`, or set `SSH_KEY`

## Usage

```bash
export QFAB_REPO=~/content-fabric    # the checkout to build and run

./dev-run.sh      # build qfab, build the image, start it; the first run also sets up chain, tenant, stream
```

| | |
|---|---|
| Fabric API | `http://127.0.0.1:8008` |
| Chain | `http://127.0.0.1:8545` |
| SRT ingest | `srt://127.0.0.1:11080` |
| Tenant | `iten2ELLakdQAKP66iniGkCXrPYPwgkf` |
| Library | `ilib29dvmbN91uyXRwcMX88CAs8q2zeT` |
| Live stream | `iq__S6M3RAZUmfpBkbMQV9RWvF7M9SF` |

The IDs are the same on every fresh setup (fixed dev keys and a fresh chain). The tenant admin's private key is
new each time: it's in `/data/state/tenant_key` in the container, and in `/data/dev.json` with everything else.

## Qfab CLI helper

Run the following for a convenient wrapper around qfab_cli which fixes the config-url and tenant private key

```bash
qcli() { podman exec qfab-dev bash -c 'qfab_cli "$@" --config-url "http://127.0.0.1:8008/config?qspace=dev&self" -x $(sed s/^0x// /data/state/tenant_key)' -- "$@"; }
```

#### Usage

```base
LIB=ilib29dvmbN91uyXRwcMX88CAs8q2zeT
QID=iq__S6M3RAZUmfpBkbMQV9RWvF7M9SF

# get stream metadata
qcli content meta get $QID /live_recording/fabric_config

# get auth token
TOKEN=$(qcli content token create $QID | jq -r .bearer)

# the HLS master playlist
curl "http://127.0.0.1:8008/qlibs/$LIB/q/$QID/rep/playout/default/hls-clear/playlist.m3u8?authorization=$TOKEN"
```


## Persistence and refreshing

State (chain, tenant, stream) is kept in the `qfab-dev-data` volume across rebuilds. To start from scratch:

```bash
podman rm -f qfab-dev && podman volume rm qfab-dev-data
```

## Live stream integration testing

The stream is configured for **25 fps, keyframe every 2s**, so convert what you send. To loop the included
`test.mp4` (30s, 1080p, 23.976 fps, no audio - silence is added):

```bash
ffmpeg -re -stream_loop -1 -i test.mp4 -f lavfi -i anullsrc=r=48000:cl=stereo -map 0:v -map 1:a \
  -vf fps=25 -c:v libx264 -preset veryfast -g 50 -pix_fmt yuv420p -c:a aac \
  -f mpegts srt://127.0.0.1:11080
```

```bash
./stream.sh status|stop|start|reset|terminate|new    # control the recording
./vertical-stream.py --interval 2                    # feed a "vertical" data stream: crop left/centre/right
```

## Run go tests

Run the go tests inside the container

`go.sh ARGS`, e.g. `./go.sh test -tags "avpipe WAPC" ./extapi/avtest/`

## Add another node
`add-node.sh`, add a second node built from `$QFAB_REPO` (e.g. another branch) - API on `:8009`

## Logs

Logs are in the container: `podman exec qfab-dev tail -f /data/RUN/qfab.log`