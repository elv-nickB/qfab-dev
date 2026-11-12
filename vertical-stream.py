#!/usr/bin/env python3
"""
Open a "vertical" data stream on the dev fabric's live stream (see dev-run.sh) and keep feeding it, so vertical
playout (add v=1 to the playlist URL) pans the 9:16 crop: left -> centre -> right -> left -> ...
switching every --interval seconds of video, on whole-second boundaries of the stream.

Data format: one little-endian uint32 per video frame, the crop centre as a fraction of the frame width
times 10000 (0 = left edge, 5000 = centre, 10000 = right edge). Record N belongs to video frame N of the
current recording period.

usage: ./vertical-stream.py [--interval 1] [--fps 25]
"""

import argparse
import json
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
from fractions import Fraction

FABRIC = "http://127.0.0.1:8008"
POSITIONS = [0, 5000, 10000]   # crop centre: left, centre, right
LEAD_SECONDS = 5               # stay this far ahead of the video
STREAM_NAME = "vertical"       # the name vertical playout looks for


# --- talking to the dev fabric ---------------------------------------------------------------------------------

def container(command):
    """Run a shell command in the qfab-dev container and return its output."""
    return subprocess.run(["podman", "exec", "qfab-dev", "bash", "-c", command],
                          check=True, capture_output=True, text=True).stdout.strip()


def http(method, url, token, body=None, content_type="application/json"):
    """Make a request to the fabric; returns (status, response body)."""
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("Authorization", "Bearer " + token)
    if body is not None:
        request.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


# --- the crop positions ----------------------------------------------------------------------------------------

def position(frame, fps, interval):
    """Crop centre for a video frame: which interval of the stream it falls in, cycling through POSITIONS."""
    seconds = frame / fps                      # exact time of the frame (fps is a fraction, e.g. 24000/1001)
    return POSITIONS[int(seconds // interval) % len(POSITIONS)]


def records(first, last, fps, interval):
    """The bytes for frames first..last-1."""
    values = [position(frame, fps, interval) for frame in range(first, last)]
    return struct.pack("<%dI" % len(values), *values)


# --- main ------------------------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--interval", type=float, default=1, help="seconds between position changes (default 1)")
    parser.add_argument("--fps", type=Fraction, default=Fraction(25), help="frame rate of the live stream (default 25)")
    args = parser.parse_args()

    # 1. Which stream, and a token that may modify it - from the setup's saved state
    library = container("cat /data/state/library_id")
    stream = container("cat /data/state/stream_id")
    token = container(
        f"qfab_cli content token create {stream} -l {library} --update"
        f" --config-url '{FABRIC}/config?qspace=dev&self' -x $(sed s/^0x// /data/state/tenant_key)"
        " 2>/dev/null | grep '^{' | jq -r .bearer")
    if not token or token == "null":
        sys.exit("failed to create an auth token for the stream")

    # Data streams belong to the running recording: its edge write token, on the node recording it (the ingress node)
    status, body = http("GET", f"{FABRIC}/qlibs/{library}/q/{stream}/meta/live_recording/fabric_config", token)
    if status != 200:
        sys.exit(f"failed to read the stream's fabric_config: {status} {body.decode()[:300]}")
    fabric_config = json.loads(body)
    recording = f"{fabric_config['ingress_node_api']}/qlibs/{library}/q/{fabric_config['edge_write_token']}/call/live"
    print(f"recording on {fabric_config['ingress_node_api']} ({fabric_config['ingress_node_id']})")

    # 2. Open the data stream - or, if this recording period already has one, carry on where it left off.
    #    (That only works within 2 minutes of the last append: after that the fabric closes the stream for good.)
    sent = 0
    status, body = http("POST", f"{recording}/data_streams", token, json.dumps({"name": STREAM_NAME}).encode())
    if status == 409:
        status, body = http("GET", f"{recording}/status", token)
        existing = json.loads(body)["custom"]["data_streams"][STREAM_NAME]
        if existing["finalized"]:
            sys.exit(f'the "{STREAM_NAME}" data stream was closed after being idle for 2 minutes'
                     ' - restart the live stream for a new recording period')
        sent = existing["records"]
        print(f"resuming the existing data stream at frame {sent}")
    elif status != 201:
        sys.exit(f"failed to open the data stream: {status} {body.decode()}")
    else:
        print(f"opened data stream: {json.loads(body)}")

    # 3. Feed it: every second, send the records up to LEAD_SECONDS ahead of the video read so far.
    #    The first round catches up from where the stream is (the start of the recording period, if new).
    lead = int(LEAD_SECONDS * args.fps)
    while True:
        status, body = http("GET", f"{recording}/status", token)
        video_frames = json.loads(body)["custom"]["status"]["video"]["frames_read"]

        target = video_frames + lead
        if target > sent:
            status, body = http("POST", f"{recording}/data_streams/{STREAM_NAME}", token,
                                records(sent, target, args.fps, args.interval), "application/octet-stream")
            if status >= 300:
                sys.exit(f"append failed: {status} {body.decode()}")
            print(f"sent frames {sent}..{target - 1}  (video at frame {video_frames}, "
                  f"now showing position {position(video_frames, args.fps, args.interval)})")
            sent = target

        time.sleep(1)


if __name__ == "__main__":
    main()
