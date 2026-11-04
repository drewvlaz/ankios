#!/usr/bin/env bash
# Build the Rust bridge for iOS device, iOS simulator and macOS (for
# `swift test`), and package it as ios/AnkiKit/Frameworks/AnkiBridgeFFI.xcframework.
#
# Usage: scripts/build-rust.sh [debug|release]   (default: release)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-release}"
CARGO_FLAGS=()
[[ "$PROFILE" == "release" ]] && CARGO_FLAGS+=(--release)

TARGETS=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
OUT="$ROOT/ios/AnkiKit/Frameworks/AnkiBridgeFFI.xcframework"
HEADERS="$ROOT/rust/ankibridge/include"

command -v protoc >/dev/null || { echo "protoc not found: brew install protobuf" >&2; exit 1; }

cd "$ROOT/rust"
rustup target add "${TARGETS[@]}" >/dev/null

for target in "${TARGETS[@]}"; do
  echo "==> cargo build ($target, $PROFILE)"
  cargo build -p ankibridge --target "$target" "${CARGO_FLAGS[@]}"
done

lib() { echo "$ROOT/rust/target/$1/$PROFILE/libankibridge.a"; }

rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$(lib aarch64-apple-ios)" -headers "$HEADERS" \
  -library "$(lib aarch64-apple-ios-sim)" -headers "$HEADERS" \
  -library "$(lib aarch64-apple-darwin)" -headers "$HEADERS" \
  -output "$OUT"

echo "==> $OUT"
