#!/usr/bin/env bash
# One-click launcher for AI Config Manager on macOS/Linux.
# Usage: curl -fsSL https://raw.githubusercontent.com/TechTronixx/Custom-modelswitch/main/bootstrap.sh | bash

set -e

DIR="$HOME/AI-Config-Manager"
mkdir -p "$DIR"

BASE_URL="https://raw.githubusercontent.com/TechTronixx/Custom-modelswitch/main"

echo "Downloading AI Config Manager..."
for FILE in "AI-Config-Manager.sh" "AI-Config-Presets.json"; do
    curl -fsSL "$BASE_URL/$FILE" -o "$DIR/$FILE"
done

chmod +x "$DIR/AI-Config-Manager.sh"

echo "Installed to: $DIR"
exec "$DIR/AI-Config-Manager.sh" "$@"
