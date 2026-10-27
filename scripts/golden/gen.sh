#!/bin/bash
# Regenerates the JDK 8 golden fixtures in Tests/Fixtures/java8/.
# Compiles with a modern JDK (--release 8) and runs on the Java 8 JRE.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
JAVA8="${JAVA8:-/Library/Internet Plug-Ins/JavaAppletPlugin.plugin/Contents/Home/bin/java}"
JAVAC="${JAVAC:-/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home/bin/javac}"
OUT="$ROOT/Tests/Fixtures/java8"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
"$JAVAC" --release 8 -nowarn -d "$BUILD" $(find "$HERE/src" -name '*.java')
"$JAVA8" -cp "$BUILD" com.ghe.golden.JavaGolden "$OUT"
