#!/bin/zsh
# The quick check for small changes: every test except the windowless renders, QA fixtures and
# performance runs, in four parallel processes (about 5 minutes, where the whole suite takes about
# 15 serially). Run the whole suite (`swift test --build-system native`) before a release.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --build-system native --build-tests -j 4
exec swift test --build-system native --skip-build --parallel --num-workers 4 \
  --skip '(Rendering|Render|QA|Snapshot|Visual|Performance|BlankFrame|Hitch|Pixel|MenuWindow|WindowRedraw)Tests' "$@"
