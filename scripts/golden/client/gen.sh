#!/bin/bash
# Regenerates the client-persistence golden fixtures in Tests/Fixtures/client/ with the Java 8 JRE.
# Uses stub classes only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
JAVA8="${JAVA8:-/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home/bin/java}"
JAVAC="${JAVAC:-/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home/bin/javac}"
OUT="$ROOT/Tests/Fixtures/client"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$OUT"
"$JAVAC" --release 8 -nowarn -d "$BUILD" $(find "$HERE/src" -name '*.java')
TZ=UTC "$JAVA8" -Djava.awt.headless=true -cp "$BUILD" com.ghe.goldenclient.ClientGolden "$OUT"
