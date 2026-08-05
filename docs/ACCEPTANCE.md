# Acceptance checklist

Run through this before tagging a release. The automated suite
(`swift run PaperSiftCheck`) covers the engine; this covers the things only a
person sitting in front of the app can see.

Prepare a scratch index so nothing here touches your real one:

```sh
swift build -c release
BENCH=/tmp/papersift-acceptance.sqlite
```

## Indexing

- [ ] `./scripts/bundle.sh` — the app opens, empty state reads sensibly, the search
      field is focused.
- [ ] **Add Folder…** on a folder of ~500 PDFs. macOS asks for permission once if
      it is in Documents/Desktop/Downloads. Indexing starts on its own.
- [ ] The sidebar counter climbs; **Index status** shows the queue draining and the
      current filename.
- [ ] **Pause** stops it, **Resume** picks up. Quit mid-way, relaunch: it continues
      from where it stopped rather than starting over.
- [ ] Roughly 1 000 pages in ~10 s on Apple Silicon. Slower is worth investigating:
      `.build/release/PaperSift --index <folder> --database $BENCH`.
- [ ] Add, edit and delete a file inside a watched folder. Within a few seconds the
      index follows — no manual rescan.
- [ ] Point it at a folder containing `node_modules` or `.git`: those are not
      indexed.

## Searching

- [ ] A two-word query returns its first useful result in **well under 300 ms**
      (the footer prints the time). Compare with `mdfind` on the same words: fewer,
      better-targeted results, at page granularity.
- [ ] Each operator behaves: `"exact phrase"`, `+required`, `-excluded`, `prefix*`.
- [ ] A suffix wildcard (`*nomic`) still finds the word **and** shows the
      "scanned" indicator with its explanation on hover.
- [ ] A query with no match says "No match" rather than showing stale results.
- [ ] Typing fast never shows results for a prefix of what you typed.
- [ ] Hovering a result shows the score breakdown.
- [ ] Click a folder in the sidebar: the search narrows to it and the field shows the
      folder's name. Click **All folders**: it widens again — both directions, any
      number of times.
- [ ] The sort control reorders by name, date, size and matching pages, "Reverse
      order" flips whichever is chosen, and the choice survives a relaunch.
- [ ] `⌘F`, `↑`/`↓`, `⌘↓`/`⌘↑`, `⌘⌥↑`/`⌘⌥↓`, `⌘O`, `⌘R` all do what the README says.
      `⌘↓` walks results with the caret still in the search field.

## Reading

- [ ] Clicking a result opens the PDF **at the right page**, scrolled to the first
      match rather than to the top of the sheet, with the words highlighted.
- [ ] Every row carries a thumbnail of its first page, and its date, size and length
      are right — check one against the Finder.
- [ ] A document with several matching pages: the chevron opens the list of them,
      each with its rank; clicking one goes straight to that page. `⌘⌥↓` walks them
      and the list scrolls to follow, the header counting "3 of 29".
- [ ] `⌘+` / `⌘−` zoom the page and `⌘0` fits it again; the level shows in the bar.
- [ ] A scanned PDF (no text layer) is searchable, is badged **OCR**, and the
      highlights land on the right words in the image.
- [ ] A `.md`, `.docx` and `.swift` file each open in the text reader, at the right
      chunk, with matches marked. Code shows monospaced, prose does not.
- [ ] **Reveal in Finder** and **Open in the default app** work from the header and
      the context menu.

## Settings

- [ ] Turning OCR off leaves scans queued — the count stays, nothing is lost.
      Turning it back on drains them.
- [ ] Changing the resolution takes effect on the next scan.
- [ ] **Back Up Index…** writes a file that opens: `PaperSift --stats --database
      <backup>` reports the same counts.
- [ ] **Move…** copies the index, offers to relaunch, and the app comes back with
      everything intact.
- [ ] **Rebuild Index** keeps the folders and re-reads everything.
- [ ] Settings → Updates reports the current version and a check completes (or
      fails with a readable message when offline).

## Packaging

- [ ] `swift build -c release -Xswiftc -warnings-as-errors` — clean.
- [ ] `swift run PaperSiftCheck` — all green.
- [ ] `./scripts/make-dmg.sh` produces a `.dmg` and a `.zip`.
- [ ] The `.dmg` installs on a machine that has never seen the app, and the
      Gatekeeper instructions in the README actually work.
- [ ] The icon looks right in the Finder at 16 px and 512 px.
