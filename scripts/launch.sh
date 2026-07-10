#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../epublibre.koplugin" && pwd)"

REMOTE_USER="root"
REMOTE_HOST="192.168.0.39"
REMOTE_PORT="2222"
REMOTE_DIR="/mnt/base-us/koreader/plugins/epublibre.koplugin/"

scp -P "$REMOTE_PORT" -r "$SCRIPT_DIR/." "$REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR"
