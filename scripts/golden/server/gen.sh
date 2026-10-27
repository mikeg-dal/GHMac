#!/bin/bash
# Regenerates the JDK 8 golden fixtures in Tests/Fixtures/server/ (test passwords and
# synthetic WIO profiles from Tests/Fixtures/server/input only).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
JAVA8="${JAVA8:-/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home/bin/java}"
JAVAC="${JAVAC:-javac}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
"$JAVAC" --release 8 -nowarn -d "$BUILD" "$HERE/ServerGolden.java"
"$JAVA8" -cp "$BUILD" com.ghe.golden.server.ServerGolden "$ROOT/Tests/Fixtures/server/input/wioProfiles" "$ROOT/Tests/Fixtures/server"
