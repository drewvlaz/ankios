#!/usr/bin/env bash
# Generate Swift code from Anki's protobuf definitions:
#   - SwiftProtobuf message types  -> Generated/Protos/*.pb.swift (gitignored)
#   - typed RPC wrappers (swiftgen) -> Generated/AnkiBackend+Services.swift (committed)
#
# protoc-gen-swift is built from the same swift-protobuf tag that
# ios/AnkiKit/Package.swift pins, so generated code and runtime always agree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_PROTOBUF_VERSION="1.38.1"
GEN="$ROOT/ios/AnkiKit/Sources/AnkiKit/Generated"
TOOLS="$ROOT/build/tools"

command -v protoc >/dev/null || { echo "protoc not found: brew install protobuf" >&2; exit 1; }

# 1. Descriptors + RPC wrappers (host build; also produces anki_descriptors.bin).
echo "==> swiftgen"
cd "$ROOT/rust"
cargo build -p swiftgen --release
./target/release/swiftgen target/anki_descriptors.bin "$GEN/AnkiBackend+Services.swift"

# 2. protoc-gen-swift at the pinned version.
PLUGIN="$TOOLS/swift-protobuf-$SWIFT_PROTOBUF_VERSION/.build/release/protoc-gen-swift"
if [[ ! -x "$PLUGIN" ]]; then
  echo "==> building protoc-gen-swift $SWIFT_PROTOBUF_VERSION"
  mkdir -p "$TOOLS"
  rm -rf "$TOOLS/swift-protobuf-$SWIFT_PROTOBUF_VERSION"
  git clone --quiet --depth 1 --branch "$SWIFT_PROTOBUF_VERSION" \
    https://github.com/apple/swift-protobuf.git "$TOOLS/swift-protobuf-$SWIFT_PROTOBUF_VERSION"
  (cd "$TOOLS/swift-protobuf-$SWIFT_PROTOBUF_VERSION" && swift build -c release --product protoc-gen-swift)
fi

# 3. Message types.
echo "==> protoc --swift_out"
rm -rf "$GEN/Protos" && mkdir -p "$GEN/Protos"
protoc \
  --plugin=protoc-gen-swift="$PLUGIN" \
  --swift_opt=Visibility=Public \
  --swift_opt=FileNaming=PathToUnderscores \
  --swift_out="$GEN/Protos" \
  -I "$ROOT/vendor/anki/proto" \
  "$ROOT"/vendor/anki/proto/anki/*.proto

echo "==> done"
