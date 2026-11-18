#!/bin/sh
# Собирает sysviz (если нужно) и запускает его.
set -e
cd "$(dirname "$0")"
swift build -c release --quiet
exec "$(swift build -c release --show-bin-path --quiet)/sysviz"
