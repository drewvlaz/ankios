#!/usr/bin/env bash
# One-shot setup on a Mac: submodules, Rust bridge, generated Swift, Xcode project.
# Prereqs: Xcode, rustup, `brew install protobuf xcodegen`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

for tool in rustup protoc xcodegen xcodebuild; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done

echo "==> submodules"
git submodule update --init vendor/anki
git -C vendor/anki submodule update --init --depth 1 ftl/core-repo ftl/qt-repo

"$ROOT/scripts/gen-swift.sh"
"$ROOT/scripts/build-rust.sh" "${1:-release}"

echo "==> xcodegen"
(cd ios && xcodegen generate)
echo
echo "Open ios/AnkiOS.xcodeproj, pick your team under Signing, and run."
