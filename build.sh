#!/bin/zsh
# Build Chimera.
#
#   ./build.sh            Debug build
#   ./build.sh run        …and launch it
#   ./build.sh cli        Build chimera-cli into build/
#   ./build.sh check      Run every strategy against a corpus and verify the output
#   ./build.sh icon       Redraw the app icon
#   ./build.sh release    Release build, Developer ID signed
#
# `pipefail` matters: every xcodebuild is piped into a filter, and without it a
# failed compile exits 0 and you spend the afternoon testing a stale binary.
set -e
set -o pipefail
cd "$(dirname "$0")"

CMD="${1:-debug}"
CORPUS="${CORPUS:-$HOME/Library/CloudStorage/OneDrive-AdvanceLocal/Desktop/songs}"

generate() { command -v xcodegen >/dev/null && xcodegen generate >/dev/null; }

case "$CMD" in
  icon)
    python3 Tools/make_icon.py
    ;;

  cli)
    mkdir -p build
    swiftc -O -o build/chimera-cli Sources/Core/*.swift Sources/CLI/main.swift
    echo "build/chimera-cli"
    ;;

  check)
    ./build.sh cli
    echo
    ./build/chimera-cli selftest "$CORPUS" --out "${OUT:-$TMPDIR/chimera-selftest}"
    ;;

  release)
    generate
    xcodebuild -project Chimera.xcodeproj -scheme Chimera -configuration Release \
      -derivedDataPath build/dd build | tail -3
    echo "build/dd/Build/Products/Release/Chimera.app"
    ;;

  run|debug)
    generate
    xcodebuild -project Chimera.xcodeproj -scheme Chimera -configuration Debug \
      -derivedDataPath build/dd build | grep -E "error:|warning:|BUILD" | tail -20
    APP="build/dd/Build/Products/Debug/Chimera.app"
    echo "$APP"
    [[ "$CMD" == run ]] && open "$APP"
    ;;

  *)
    echo "usage: ./build.sh [debug|run|cli|check|icon|release]" >&2
    exit 1
    ;;
esac
