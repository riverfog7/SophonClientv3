#!/bin/bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT=$(realpath "$SCRIPT_DIR/..")
PROTO_DIR="$REPO_ROOT/Proto"
OUT_DIR="$REPO_ROOT/Sources/SophonClientv3/Proto"

if [ -d "$OUT_DIR" ]; then
	rm -r "$OUT_DIR"
fi

mkdir -p "$OUT_DIR"
protoc --swift_out "$OUT_DIR" --proto_path "$PROTO_DIR" "$PROTO_DIR"/*.proto

