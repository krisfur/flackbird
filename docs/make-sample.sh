#!/bin/bash
# Regenerates sample.flac, the track App Store reviewers download to have
# something to play. Everything here is generated rather than sourced from a
# music library, so the file carries no licence and nothing to attribute.
#
# Needs ffmpeg and metaflac (brew install ffmpeg flac); swift ships with Xcode.
set -euo pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 sample-tone.py "$WORK/tone.wav"
swift sample-cover.swift "$WORK/cover.png"

ffmpeg -loglevel error -y -i "$WORK/tone.wav" -c:a flac -compression_level 12 \
    -metadata title="Sample Tone" \
    -metadata artist="Flackbird" \
    -metadata album="Flackbird Sample" \
    -metadata date="2026" \
    -metadata comment="Original test tone, no rights reserved. Public domain." \
    sample.flac

metaflac --import-picture-from="$WORK/cover.png" sample.flac

flac --test sample.flac
ls -lh sample.flac
