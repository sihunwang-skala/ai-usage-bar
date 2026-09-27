#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build --product AIUsageBar
build_dir="$(swift build --show-bin-path)"
exec "$build_dir/AIUsageBar"
