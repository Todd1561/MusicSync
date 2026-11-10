#!/bin/bash
# Runs the sync engine tests. The plugin path lets the Command Line Tools
# (without full Xcode) find the Swift Testing macros.
set -euo pipefail
cd "$(dirname "$0")"
swift test --scratch-path "$HOME/Library/Caches/MusicSync-build" \
  -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
