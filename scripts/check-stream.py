#!/usr/bin/env python3
"""Capture one bounded LDV1 session. Use port 24833 for the optional USB round trip."""
import argparse
import json
import socket
import struct
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=24832)
parser.add_argument('--seconds', type=float, default=8)
parser.add_argument('--width', type=int, default=2880)
parser.add_argument('--height', type=int, default=1920)
parser.add_argument('--fps', type=int, choices=[60,120,144])
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)

with socket.create_connection(('127.0.0.1', args.port), timeout=5) as sock:
    def read_exact(size):
        data = bytearray()
        while len(data) < size:
            chunk = sock.recv(size - len(data))
            if not chunk:
                raise EOFError('Stream ended before a complete packet was received')
            data.extend(chunk)
        return bytes(data)

    magic, width, height, fps = struct.unpack('>4sIII', read_exact(16))
    if magic not in (b'LDV1', b'LDH1') or (width, height) != (args.width, args.height) or fps not in (60,120,144) or (args.fps is not None and fps != args.fps):
        raise ValueError('Unexpected stream header')
    start = time.monotonic()
    frames = total = keyframes = 0
    first_pts = last_pts = None
    with args.output.open('wb') as file:
        while time.monotonic() - start < args.seconds:
            sock.settimeout(max(.1, args.seconds - (time.monotonic() - start)))
            try:
                size, flags, pts = struct.unpack('>IIQ', read_exact(16))
                if not 0 < size <= 8 * 1024 * 1024 or flags not in (0, 1):
                    raise ValueError('Invalid packet size or flags')
                payload = read_exact(size)
            except TimeoutError:
                break
            if not payload.startswith(b'\x00\x00\x00\x01'):
                raise ValueError('Expected Annex B H.264/HEVC')
            if not frames and not flags:
                continue  # A reconnect may see older in-flight P frames before its first IDR.
            if last_pts is not None and pts < last_pts:
                raise ValueError('Presentation timestamps moved backwards')
            if first_pts is None:
                first_pts = pts
            last_pts = pts
            file.write(payload)
            frames += 1
            total += size
            keyframes += flags
    seconds = time.monotonic() - start
    if frames == 0 or keyframes == 0:
        raise RuntimeError('No decodable keyframe received')
    result = dict(width=width, height=height, target_fps=fps, codec='hevc' if magic==b'LDH1' else 'h264', frames=frames, keyframes=keyframes,
                  bytes=total, duration_seconds=round(seconds, 3),
                  received_fps=round(frames / seconds, 2), port=args.port,
                  pts_span_seconds=round((last_pts - first_pts) / 1e6, 3))
    args.output.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
