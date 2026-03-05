#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-artifacts/ui}"
mkdir -p "$OUT_DIR"

swift run orbit-menubar --capture-ui "$OUT_DIR"
