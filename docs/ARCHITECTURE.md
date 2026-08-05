# Architecture

PaperSift is two targets: `PaperSiftCore`, which contains everything that can be
tested without a window, and `PaperSift`, the SwiftUI shell plus a CLI that drives
the same engine. A third target, `PaperSiftCheck`, is the test suite (see
[CONTRIBUTING.md](../CONTRIBUTING.md) for why it is an executable).

Everything is built on frameworks macOS already ships. That is a design
constraint, not a coincidence: PDFKit reads PDFs *and* reports font sizes,
NaturalLanguage lemmatizes, Vision does OCR, SQLite has FTS5 compiled in. Adding a
dependency would mean giving one of those up.

## The pipeline

```
FSEvents ─┐
          ├─→ DocumentScanner ─→ IndexStore (queue) ─→ IndexCoordinator
Add Folder ┘                                              │
                                                          ├─→ TextExtractor ─┐
                                                          │                  ├─→ Lemmatizer ─→ IndexStore (pages + FTS5)
                                                          └─→ OCRService ────┘
```

- **`DocumentScanner`** walks a folder, keeps files whose extension an extractor
  claims, and prunes whole subtrees (`node_modules`, `.git`, `build`, …). Source
  code is indexable, which makes that pruning load-bearing rather than tidy.
- **`IndexStore`** is an `actor` owning one SQLite connection. Everything goes
  through it, which is both correct (one writer) and fast enough — searches are
  milliseconds.
- **`IndexCoordinator`** is the pipeline. It reconciles what is on disk with what
  is indexed, then drains two queues: text first, then OCR. The queues live in
  SQLite, so quitting mid-way and relaunching resumes rather than restarts.
- **Extractors** are one struct per family behind a `TextExtractor` protocol.
  Formats with no pages of their own (text, Word, HTML) are cut into ~3 000
  character chunks by `PageChunker`, which play the role pages play everywhere else.

### Why `nonisolated` matters

`IndexCoordinator` is an actor, but the two methods that do the work —
`extractText` and `recognize` — are `nonisolated`. That is the difference between
extracting eight documents at once and extracting them one at a time behind the
actor's queue. The actor still owns the counters and the pause flag; the workers
receive an immutable settings value and report back through `Outcome`.

Making either method isolated "to be safe" would silently serialize indexing.

## The database

One file, `index.sqlite`, in WAL mode. Six tables:

```
roots(id, path, bookmark, added_at)
documents(id, root_id, path, filename, ext, size, mtime, page_count, state, needs_ocr, error, …)
pages(id, doc_id, page_no, char_count, from_ocr)
pages_fts(body, title, lemmas)          -- FTS5, unicode61 remove_diacritics 2, prefix='2 3 4'
ocr_layout(page_id, data)               -- JSON word boxes, normalized 0…1
index_queue(doc_id, kind, enqueued_at)  -- 'text' or 'ocr'
```

Two decisions worth knowing before you touch `Schema.swift`:

- **`pages.id` and `pages_fts.rowid` are kept aligned.** A page's text is inserted
  into the FTS table under the rowid the `pages` row just received, which is what
  lets a search join metadata and matches without a lookup table.
- **The FTS table stores the text** instead of using `content=''`. A contentless
  FTS5 table cannot serve `snippet()` or `highlight()`, and text is cheap — roughly
  1 MB per 500 pages.

FTS5 rows are **not** reached by foreign-key cascades. Deleting a document or a
root therefore clears `pages_fts` explicitly, in the same transaction. Forgetting
this is how an index starts returning pages that no longer exist.

### Three columns, three jobs

`body` is the page. `title` is the text that looked like a heading — large or bold
runs from `PDFPage.attributedString`, Markdown `#` lines, taller-than-usual lines
on an OCR'd page. `lemmas` holds the dictionary forms that differ from what was
written, so "children" finds "child". bm25 weights them 1 / 3 / 0.6: a heading
match is worth more than a body match, a lemma match is worth less than either.

## Searching, in two stages

```
"turbine +gearbox -draft"
      │
      ├─ QueryParser → FTS5 expression: "turbine" AND "gearbox" NOT ("draft")
      │                (every term a quoted literal — FTS5 keywords and stray
      │                 quotes in user input cannot become syntax)
      │
      ├─ Stage 1, SQLite: MATCH + ORDER BY bm25(…) LIMIT 300
      │
      └─ Stage 2, Swift: Ranker re-scores those 300 pages
                         → group by document → best page first
```

SQLite is very good at *which pages contain these words* across hundreds of
thousands of rows. It knows nothing about how close the words sit or whether they
landed in a heading. So the index picks a shortlist and `Ranker` decides the order.

The shortlist is why worst-case latency is bounded by 300 pages rather than by the
size of your library: ~40 ms for a broad three-word query, ~1 ms for a selective
one, whether you indexed a thousand pages or a hundred thousand.

Each component is normalized to 0…1 before being weighted (`RankingWeights`):

| Component | Meaning |
|---|---|
| `relevance` | bm25, normalized against the best candidate in the set |
| `coverage` | share of query terms the page actually carries — the strongest signal |
| `proximity` | tightest window containing all matched terms, **scaled by coverage** |
| `density` | occurrences relative to page length |
| `title` | share of terms found in the heading column |
| `recency` | `exp(-age / 365 days)` |

The "scaled by coverage" is not decoration. Without it a page repeating one word
five times scores a perfect proximity (a single term is trivially close to itself)
and outranks a page containing every word you asked for. That bug is in the test
suite now.

### Tokenizing has to agree with the index

`Tokenizer` splits on non-alphanumerics, lowercases and strips diacritics —
matching FTS5's `unicode61 remove_diacritics 2`. If it drifted, the ranker would
score words SQLite never matched.

It iterates **unicode scalars, not characters**: grapheme segmentation was the
single most expensive thing about ranking a shortlist (134 ms → 39 ms for the same
query when it changed). Combining marks count as word characters, which is
load-bearing for decomposed text — PDF text often arrives as `e` + U+0301, and
treating the accent as a separator would cut `économique` into `e` and `conomique`.

## OCR

A page whose text layer yields fewer than 30 characters is a scan. It stays in the
index as an empty page (so it can be replaced in place) and its document moves from
the text queue to the OCR queue.

`PageRasterizer` renders it at 200 dpi in grayscale — a third of the memory of RGB,
and OCR does not care about colour. `OCRService` runs Vision's
`RecognizeTextRequest`, keeps lines above a confidence floor, and records a box per
word via `RecognizedText.boundingBox(for:)`. Those boxes are what let the viewer
highlight the right word on an image with no text in it.

Headings come from line height rather than Vision's own `isTitle`: that property
needs the macOS 26 SDK, and referring to it would stop the project compiling on a
CI runner with an older one.

## Highlighting, twice

- A normal PDF page: matches are found in the page's own text and shown with
  `PDFView.highlightedSelections`.
- An OCR'd page: there is no text to select, so the stored word boxes become
  temporary `PDFAnnotation`s, removed when the selection moves.

Neither path ever writes to the user's file.

## Concurrency map

| Type | Isolation | Why |
|---|---|---|
| `IndexStore` | `actor` | one SQLite writer, many callers |
| `IndexCoordinator` | `actor`, workers `nonisolated` | counters need protection, extraction needs parallelism |
| `SearchEngine`, `Ranker`, extractors | `Sendable` structs | pure functions over values |
| `FolderWatcher` | `@unchecked Sendable` | FSEvents calls back on our own serial queue |
| `LibraryModel` | `@MainActor @Observable` | the single bridge between views and actors |
