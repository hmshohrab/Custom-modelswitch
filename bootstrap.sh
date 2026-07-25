#!/usr/bin/env bash
# One-click launcher for AI Config Manager on macOS/Linux.
# Usage: curl -fsSL https://raw.githubusercontent.com/hmshohrab/Custom-modelswitch/main/bootstrap.sh | bash

set -e

DIR="$HOME/AI-Config-Manager"
mkdir -p "$DIR"

# Determine best repo/branch to pull from
REPO="hmshohrab/Custom-modelswitch"
BRANCH="main"
if ! curl -fsI "https://raw.githubusercontent.com/$REPO/main/AI-Config-Manager.sh" >/dev/null 2>&1; then
    BRANCH="mac/linux-version"
fi

BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"
TS=$(date +%s)

echo "Downloading AI Config Manager from $REPO ($BRANCH)..."
for FILE in "AI-Config-Manager.sh" "AI-Config-Presets.json"; do
    curl -fsSL "$BASE_URL/$FILE?v=$TS" -o "$DIR/$FILE"
done

chmod +x "$DIR/AI-Config-Manager.sh"

echo "Installed to: $DIR"
exec "$DIR/AI-Config-Manager.sh" "$@"
