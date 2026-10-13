#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build
FIXTURE_DIR="$(mktemp -d "$ROOT_DIR/build/index-benchmark.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
swiftc -parse-as-library -O -module-cache-path build/ModuleCache \
  UpdateBar/Models.swift UpdateBar/VersionComparator.swift \
  UpdateBar/Checkers/{UpdateChecker,IndexCache,HomebrewChecker,FormulaChecker,SparkleChecker}.swift \
  script/benchmark_indexes.swift -o "$FIXTURE_DIR/benchmark"
"$FIXTURE_DIR/benchmark" "$FIXTURE_DIR"
