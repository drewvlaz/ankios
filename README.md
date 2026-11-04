# ankios

A personal iOS client for Anki. It opens your existing collection and syncs
with AnkiWeb (or a self-hosted Anki sync server). The scheduler, collection
storage, card rendering and sync all come from Anki's own Rust core. The
SwiftUI front end is written from scratch.

Licensed AGPL-3.0-or-later, because it links Anki's `rslib`. It is meant for
personal use, not App Store distribution.

## Layout

```
vendor/anki/          Anki source, pinned submodule (currently 26.09.4)
rust/ankibridge/      C ABI over rslib: protobuf bytes in, protobuf bytes out
rust/swiftgen/        Generates typed Swift RPC wrappers with rslib's own indices
ios/AnkiKit/          Swift package: backend wrapper + domain layer (no UIKit)
  Generated/            AnkiBackend+Services.swift (committed), Protos/ (generated)
ios/App/              SwiftUI app
ios/project.yml       XcodeGen spec for the app target
scripts/              bootstrap / build-rust / gen-swift
```

### How a call flows

```
SwiftUI view ─► AppModel / StudySession ─► AnkiKit (Reviewer, sync, deckList)
   ─► AnkiBackend.getQueuedCards(...)            generated, typed
   ─► run(service: 13, method: 3, input:)        SwiftProtobuf encode
   ─► anki_backend_run(...)                      C ABI, background queue
   ─► rslib Backend::run_service_method          Anki's dispatcher
```

Service and method numbers come from `anki_proto_gen::get_services`, the same
function rslib's dispatcher is generated from. Never number RPCs by hand. To
bump Anki, check out a new tag in `vendor/anki`, update `rust-toolchain.toml`
to match, and run `scripts/gen-swift.sh`. The diff of
`AnkiBackend+Services.swift` shows exactly which RPCs moved.

## Setup (macOS)

Prerequisites: Xcode 16+, [rustup](https://rustup.rs), and
`brew install protobuf xcodegen`.

```sh
git clone --recurse-submodules <this repo>
scripts/bootstrap.sh          # submodules, generated Swift, Rust XCFramework, Xcode project
open ios/AnkiOS.xcodeproj     # set your signing team, run on a device or simulator
```

The first Rust build takes several minutes. After changing Rust code, run
`scripts/build-rust.sh` (pass `debug` for faster builds). After bumping Anki,
run `scripts/gen-swift.sh`.

The simulator slice is arm64 only (Apple Silicon Macs).

## Tests

```sh
cd rust && cargo test            # runs anywhere: FFI study flow + sync round-trip
cd ios/AnkiKit && swift test     # macOS: AnkiKit against the real backend
```

The Rust tests drive the C ABI exactly as Swift does. They include a full
upload, a full download to a fresh "device", and a normal sync of a review
back, all against Anki's bundled sync server.

## Sync behaviour

- **First login** on an empty collection: the backend reports
  `FULL_DOWNLOAD` and the app downloads automatically. Media follows in the
  background.
- **Normal syncs** run on launch, on pull-to-refresh, when returning to the
  app (at most every 5 minutes), and when leaving the app. The leaving-the-app
  sync is collection only, within iOS's ~30s background window.
- **Diverged collections** (`FULL_SYNC`): the app never chooses a direction
  on its own. You pick Download or Upload in a confirmation dialog.
- AnkiWeb can redirect a user to a different shard via `new_endpoint`. The
  app persists the new endpoint in the Keychain alongside the host key. The
  password is never stored.
- **Self-hosted servers**: set the URL on the login screen, e.g.
  `http://192.168.1.10:8080/`. Run the server with `anki --syncserver` or see
  Anki's manual. HTTP goes through rslib's own client, so iOS App Transport
  Security doesn't apply.

## Status

Working (Rust side tested; Swift side written but not yet compiled, see below):
login, deck list with counts, studying with the v3 scheduler (FSRS or SM-2,
whatever your collection uses), interval labels, undo, bury/suspend, images
and audio from the media folder, TTS tags, night mode, sync with progress and
cancel, media sync, check database.

Not yet implemented:
- MathJax (needs the MathJax bundle in the web view)
- type-in-the-answer: the field is stripped from the card
- image occlusion and other cards that rely on Anki's bundled JS
- custom scheduling JS from deck options
- adding/editing notes, browser, deck options, statistics
- the answer-time cap is fixed at 60s instead of read from deck options

## Caveat: the Swift code hasn't been compiled yet

It was written against the generated APIs (SwiftProtobuf naming rules, the
swiftgen output), but the first build on a Mac is its first compile. Expect
small fixes.
