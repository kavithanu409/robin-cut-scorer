#!/bin/sh
# Push to GitHub Pages only if the refresh regression test passes locally.
set -e
cd "$(dirname "$0")"
[ -d tests/node_modules ] || npm i --prefix tests --silent
python3 -m http.server 8765 >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1
node tests/refresh-test.js || { echo "Refresh test failed: NOT deploying."; exit 1; }
git -c credential.helper= -c credential.helper='!gh auth git-credential' \
  push -q https://github.com/kavithanu409/robin-cut-scorer.git main
echo "Pushed. Live in about a minute: https://kavithanu409.github.io/robin-cut-scorer/"
