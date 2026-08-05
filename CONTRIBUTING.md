# Contributing to PaperSift

Thanks for considering it. This project is deliberately small to hack on: no
dependencies, no Xcode, no code generation.

## Dev setup

You only need **Command Line Tools** (`xcode-select --install`):

```sh
swift build                    # debug build
swift run PaperSiftCheck       # the test suite (see below)
./scripts/bundle.sh            # release build → build/PaperSift.app, ad-hoc signed, launched
./scripts/bundle.sh --no-open
./scripts/build-iconset.sh     # regenerates Resources/AppIcon.icns from code
./scripts/make-dmg.sh          # release .dmg + .zip for the updater, and the cask's sha256
swift scripts/demo-corpus.swift  # synthetic documents in "/tmp/PaperSift Demo"
```

`demo-corpus.swift` is how you get something to search without handing over your
own files, and it is what the README screenshots are taken on: two dozen reports
with a real text layer, one PDF whose pages are *pictures* of text (the OCR path),
a Markdown file, a Swift file, and a `node_modules` folder that must never show up
in a result. It is seeded, so it produces the same corpus every time.

Fast feedback loop while developing — the CLI drives the same engine the window
does, against a scratch index:

```sh
.build/debug/PaperSift --index ~/Documents/papers --database /tmp/scratch.sqlite
.build/debug/PaperSift --search "turbine +gearbox -draft" --database /tmp/scratch.sqlite
.build/debug/PaperSift --search "annual report" --repeat 5   # warm-up vs steady-state latency
.build/debug/PaperSift --stats --database /tmp/scratch.sqlite
.build/debug/PaperSift --database /tmp/scratch.sqlite --query "kirkwall"   # open the window on it
```

When a file will not index, `--diagnose` says which extractor claimed it and what
went wrong — start there rather than guessing:

```sh
.build/debug/PaperSift --diagnose ~/Documents/that-one.pdf
.build/debug/PaperSift --failures --database /tmp/scratch.sqlite       # everything that produced no pages
.build/debug/PaperSift --retry-failures --database /tmp/scratch.sqlite # after a fix, give them another go
```

## Why the tests are an executable

`swift test` does **not** work here, and that is not an oversight: neither
`Testing` nor `XCTest` ships with the Command Line Tools, only with Xcode. Rather
than make every contributor install 10 GB of Xcode, the suite is an executable
target with a 60-line harness (`Sources/PaperSiftCheck/Harness.swift`):

```sh
swift run PaperSiftCheck     # → "✅ 368 checks in 66 cases — all passed"
```

Same reason SwiftData is absent (its macros live in Xcode) and why you will not
find `#Preview` anywhere: the previews macro plugin is an Xcode component too.

Fixtures are **generated at runtime**, never committed: `PDFFixtures` draws real
PDFs with CoreText, including picture-only ones for the OCR path, and AppKit
writes the `.docx` and `.rtf` samples. A new format check should follow that
pattern rather than add binary files to the repo.

## Project map

| Path | What lives there |
|---|---|
| `Sources/PaperSiftCore/Store/` | `SQLiteConnection` (raw C API), schema and migrations, `IndexStore` — the actor that owns the database |
| `Sources/PaperSiftCore/Extraction/` | one extractor per family, plus `PageChunker` for formats with no pages |
| `Sources/PaperSiftCore/Index/` | `DocumentScanner`, `IndexCoordinator` (the pipeline), `FolderWatcher` (FSEvents) |
| `Sources/PaperSiftCore/OCR/` | `PageRasterizer`, `OCRService` (Vision), `OCRLayout` (word boxes) |
| `Sources/PaperSiftCore/Search/` | `Tokenizer`, `QueryParser`, `SearchEngine`, `Ranker`, `RankingWeights`, `Lemmatizer` |
| `Sources/PaperSift/` | SwiftUI app: `LibraryModel` is the only thing that talks to the actors |
| `Sources/PaperSiftCheck/` | the suite and its fixture generators |
| `docs/ARCHITECTURE.md` | how the pieces fit, and why |
| `docs/ACCEPTANCE.md` | manual checklist before tagging a release |

## Conventions

- Swift 6 strict concurrency. Services that own state are `actor`s; the CPU-bound
  halves are `nonisolated` on purpose, so they run in parallel instead of queuing
  behind an actor. If you make one isolated "for safety", indexing goes serial.
- The UI layer is `@MainActor @Observable`; views never `await` a store directly.
- `swift build -Xswiftc -warnings-as-errors` must stay clean.
- **No new dependencies.** If something needs a library, it probably needs a
  different design — or macOS already has it.
- UI strings and comments in English.
- Comments explain *why*, not *what*. The ranking weights, the encoding order and
  the `nonisolated` annotations all carry the reason they are that way; please keep
  that up when you change them.
- Small, focused commits with imperative subjects.

## The bar for a PR

1. `swift build -Xswiftc -warnings-as-errors` is clean.
2. `swift run PaperSiftCheck` passes, with a new case for whatever you changed.
3. If it touches indexing or ranking, say what you measured:
   `--index` on a real folder and `--search --repeat 5` before/after.
4. If it touches the UI, a screenshot.

## Cutting a release

Three places carry the version and they have to agree, or the updater refuses its
own download (it checks the bundle's identifier and version before replacing
anything):

1. Bump `CFBundleShortVersionString` in `Resources/Info.plist`.
2. Walk `docs/ACCEPTANCE.md`.
3. `./scripts/make-dmg.sh` — writes `build/PaperSift-X.Y.Z.dmg` and `.zip`, and
   prints the `.zip`'s sha256.
4. `gh release create vX.Y.Z build/PaperSift-X.Y.Z.dmg build/PaperSift-X.Y.Z.zip
   --title "PaperSift X.Y.Z" --notes-file <notes>`.
5. Update `Casks/papersift.rb` in
   [imadhy/homebrew-tap](https://github.com/imadhy/homebrew-tap) with the new
   version and that sha256, then `brew audit --cask` it.

The `.zip` filename is a contract: when GitHub's API is rate limited the updater
falls back to guessing the asset URL as `PaperSift-<version>.zip`, so renaming it
breaks self-updates for anyone behind a busy IP.

## Ideas that would be genuinely welcome

- **Tags and bookmarks** — the original has them and PaperSift does not yet.
- **Export the best pages as one PDF**, the original's signature trick.
- **Semantic search** as a *second* recall stage (`NLContextualEmbedding`), fused
  with bm25 rather than replacing it.
- **A suffix index** (reversed tokens) so `*nomic` stops needing a scan.
- **Localization**, now that the strings are in one language on purpose.
