# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Octavo — a native macOS replacement for calibre (1 GB) whose job is syncing an ebook library to a
Kindle Paperwhite 12 and editing metadata. SwiftPM package, no external dependencies: MTP is written
directly on IOUSBHost, SQLite and zlib come from the SDK. The built `.app` is ~3.8 MB: 1.7 MB of it is
the original binary, then `Octavo.icns`, then the AZW3/KF8 writer.

Two icons exist side by side, drawn by sibling scripts from the same sheet/dog-ear geometry:
`Resources/Octavo.icns` (`make-icon.swift`), which `make-app.sh`'s release build embeds, and
`Resources/Octavo.icon` (`make-liquid-icon.swift`), a Liquid Glass `.icon` bundle — icon.json plus
a transparent-background glyph PNG in `Assets/`, editable in Icon Composer.app (ships inside
Xcode 26) — which only the Tuist-generated `Octavo.xcworkspace` target consumes, via
`ASSETCATALOG_COMPILER_APPICON_NAME` in `Project.swift`. The plate is not rasterized for the
`.icon`: its gradient is `fill`/`fill-specializations` in icon.json, and the system renders the
rounded-square mask, glass material and specular sheen around the one foreground glyph layer.

It operates **in place on the user's real calibre library** at `~/Calibre Library` (42 books) — same
`metadata.db`, same folder layout, so calibre keeps working alongside it.

**calibre the application is not required.** `CalibreLibraryStore.create(at:)` lays down calibre's
own schema (`CalibreSchema.sql`, copied verbatim from `metadata_sqlite.sql`, `user_version=26`), so
a library Octavo made opens in calibre later with no migration. Which library is open is resolved by
`LibraryLocation`: the path remembered under `LibraryRoot` in the `org.octavo.Octavo` defaults suite
(a suite, not `.standard`, so the CLIs see what the app sees), else `~/Calibre Library` if it exists,
else nothing — and *nothing* is the welcome screen (`AppModel.LibraryState.needsSetup`), which is
deliberately distinct from `.failed`: one offers to create a library, the other reports a broken one.

## Commands

```sh
swift build                              # libraries + CLIs
swift test                               # whole suite, offline: the catalogue tests are skipped
OCTAVO_NETWORK_TESTS=1 swift test        # …including the three tests that hit the live catalogues
swift test --filter convertsEPUB         # one test (regex on the test function name, not a shell glob)
./Scripts/make-app.sh                    # build/Octavo.app (release build + bundle + ad-hoc sign)
OCTAVO_VERSION=1.2 OCTAVO_BUILD=7 ./Scripts/make-app.sh   # what the release workflow does
open build/Octavo.app
swift Scripts/make-icon.swift            # redraws Resources/Octavo.icns; only after changing artwork
swift Scripts/make-liquid-icon.swift     # redraws Resources/Octavo.icon (Liquid Glass); only after changing artwork
open Package.swift                       # opens the package in Xcode; the Octavo scheme runs, but without a bundle
tuist generate                           # builds Octavo.xcworkspace from Project.swift: Octavo runs as a real .app (bundle id, Info.plist, Resources/Octavo.icon) + one scheme per test target; gitignored, rerun after Project.swift/Package.swift changes
```

CLIs, all of which talk to a connected Kindle:

```sh
.build/debug/mtpprobe                    # USB descriptors, MTP session, device contents — read-only
.build/debug/mtpprobe --ls system        # list a folder;  --cat path  dumps a file to stdout
.build/debug/mtpprobe --push f  --rm n   # write/delete a single file in documents/
.build/debug/octavo-sync                 # dry run: what a sync would do, writes nothing
.build/debug/octavo-sync --apply         # real sync (pulls a documents/ backup first unless --no-backup)
.build/debug/octavo-sync --library PATH  # a library other than the resolved one
.build/debug/octavo-sync --format mobi   # override Settings ▸ Conversion for one run
.build/debug/octavo-convert book.epub    # conversion alone (--format azw3|mobi; default is the app's setting)
```

**The MTP interface is claimed exclusively.** While Octavo.app runs, every CLI fails with "The MTP
interface is busy in another process", and vice versa. `pkill -x Octavo` before using the CLIs.

### Releasing

`.github/workflows/release.yml` fires on a `v*` tag: it stamps the tag into the bundle through
`OCTAVO_VERSION`, archives with `ditto -c -k --keepParent` (plain `zip` drops the xattrs an ad-hoc
signature relies on), re-verifies the unpacked copy, and publishes the zip plus a CLI tarball and
`SHA256SUMS.txt`. It is **not idempotent** — a failed run after the tag was pushed needs
`gh release delete <tag> --yes` and the tag deleted on both sides before re-tagging. Both workflows
pin `runs-on: macos-26`; an unpinned `macos-latest` would let the toolchain move between a green CI
run and a release build. The shipped app is ad-hoc signed and not notarized, so users must clear
`com.apple.quarantine` — the README says so, and `Control-click ▸ Open` is not an alternative on
macOS 15+.

## Architecture

```
MTPKit        PTP/MTP over IOUSBHost: transport, container codec, session, operations, hotplug watcher
CalibreLibrary  read/write metadata.db in calibre's schema, book import, metadata.opf
KindleFormat  zip reader, metadata parsers (EPUB/MOBI/FB2/PDF/CBZ), AZW3/KF8 + MOBI 6 writers, converters
MetadataFetch Open Library + FantLab + Google Books
SyncEngine    library↔device diff, on-device manifest, conversion cache, transfer
Octavo        SwiftUI app (AppModel + DeviceController actor)
```

Dependency direction is one-way: `Octavo → SyncEngine → {MTPKit, CalibreLibrary, KindleFormat}`.
`CalibreLibrary` deliberately knows nothing about ebook formats — the caller reads metadata with
`KindleFormat` and hands over a `NewBook`.

The toolbar carries no device text. `DeviceStatusButton` (`Views/DeviceStatusButton.swift`) renders
`DeviceController.State` as one fixed-width, state-tinted glyph; the name/space/error detail that
used to sit inline in the toolbar lives in its popover instead, so `.failed` vs `.waitingForMTP` is
now a tint difference (orange vs secondary), not a wording one — `.failed` is still reserved for
actionable errors, per the rule above.

### Concurrency

`MTPTransport`/`MTPSession`/`SyncEngine` are not Sendable and must never cross a concurrency
boundary. They are created and used exclusively inside `DeviceController` (an actor); everything the
UI receives back is a Sendable value type. `AppModel` is `@MainActor @Observable`.

### Connection lifecycle

Connection is **notification-driven, not polled and not one-shot**. `USBWatcher.events()` wraps
`IOServiceAddMatchingNotification` and yields an `AsyncStream` of `.deviceAttached` / `.mtpReady` /
`.detached`; `AppModel.watchDevice()` consumes it for the lifetime of the window. The watcher's
initial arming drain reports hardware that is already plugged in, so **launch-time connect and
hot-plug are the same code path** — there is no separate "connect on appear".

Two things here cost time to work out:

- **The vendor filter must live under `kIOPropertyMatchKey`.** `IOServiceMatching("IOUSBHostDevice")`
  with `idVendor` set at the *top* level of the dictionary matches nothing at all — silently, with
  `KERN_SUCCESS` and an empty iterator. `IOUSBHostDevice`/`IOUSBHostInterface` do not implement the
  old IOUSBFamily behaviour of honouring `idVendor` there. Verified both ways against the device.
- **An iterator from `IOServiceAddMatchingNotification` is not armed until it has been emptied once.**
  Every registration is followed by a drain, and the matched drains call the same instance methods
  the callbacks do, so the two cannot drift apart.

`.mtpReady` comes from watching the *interface*, not just the device, because
`kIOMatchedNotification` on the device fires before its interfaces are published. Interface entries
carry `idVendor` too, which is what makes that possible.

`DeviceController.State.failed` no longer means "no Kindle" — that is `.disconnected`, and a Kindle
that is present but charge-only or locked is `.waitingForMTP` (grey, informational). `.failed` is
reserved for actionable errors, chiefly `interfaceBusy`, which is reported immediately without retry
because retrying cannot help.

`AppModel.deviceEpoch` is bumped on every detach; every post-`await` mutation in `connect`/`sync`/
`refreshPlan` is fenced with `guard epoch == deviceEpoch`. This is what stops a cable pull during a
transfer from showing both a transfer error and "Kindle not connected" — detach always wins.

### Sync state

Lives on the device in `documents/.octavo.json`, keyed by calibre book uuid. On first run Octavo
adopts calibre's own `metadata.calibre` from the storage root so books already there are not
re-uploaded.

`SyncEngine.isStale` decides re-sends from three signals: the device file differs from what the
manifest recorded, the library file changed size, or the book's metadata was edited after sending.
**Never compare the device file size to the library file size directly** — calibre rewrites EXTH
metadata during transfer, so its copies are a few bytes larger than the library original.

## Hard-won constraints

These cost debugging time; do not rediscover them.

- **calibre's schema triggers call Python functions.** `books_insert_trg`, `books_update_trg`,
  `series_insert_trg` and `series_update_trg` call `title_sort()` and `uuid4()`. Any process writing
  to `metadata.db` must register its own implementations (`CalibreFunctions.register`) or every
  INSERT/UPDATE fails with "no such function". Avoid the `tag_browser_filtered_*` views, which also
  need `books_list_filter`/`concat`/`sortconcat` — they are *created* fine by `CalibreSchema` (SQLite
  only stores a view's text), they just cannot be queried.
- **The schema goes in through `SQLiteDatabase.execute`, never `prepare`.** `execute` is
  `sqlite3_exec`, the one multi-statement path; `prepare` passes a nil tail pointer, so it would
  silently run `CREATE TABLE authors` and drop the other 640 lines.
- **MOBI header offsets were recovered by scanning reference files**, not from documentation — see
  `MOBIHeader`. Two of them are traps: DRM offset/count at `0x98`/`0x9C` (four bytes off and the
  Kindle treats the book as encrypted, reporting "Unable to open item"), and the NCX index at `0xE4`,
  which must be `0xFFFFFFFF` when absent because `0` points at the header record. The writer
  addresses the header by offset rather than appending sequentially, precisely to prevent shifts.
- **Conversion targets AZW3/KF8 by default; MOBI 6 is a fallback**, chosen in Settings ▸ Conversion
  or with `--format` on either CLI. MOBI 6 stays because firmware 5.19.5 was verified on the device
  to open it and it has no index structures to get wrong — but it drops every stylesheet, which is
  the whole reason AZW3 is the default.
- **The KF8 format was recovered by decoding calibre's own AZW3 files**, not from documentation, and
  `Tests/KindleFormatTests/KF8File.swift` is the reader that did it. It is proved against all 30
  corpus AZW3 files (`KF8CorpusTests`) *before* it is pointed at our own output (`KF8WriterTests`);
  keep that ordering, because a validator that only agrees with the writer it validates proves
  nothing. Four things there are not what their names suggest:
  a chunk index entry's **name is an insert position biased by its skeleton's flow offset**;
  chunk tag 6's first value counts chunk bytes **within the current section**, resetting at each;
  calibre writes every skeleton tag **twice** (`[n, n]`, `[start, len, start, len]`) and we write
  it once, which the control byte makes legal; and INDX varints set the high bit on the **last**
  byte, the opposite of most varint encodings.
- **`kindle:pos:fid:XXXX:off:YYYYYYYYYY` links are patched in after chunking**, which is why
  `KF8Markup` writes a fixed-width placeholder first. Filling it in must not move a single byte or
  every offset already recorded goes wrong.
- **Text records are exactly 4096 uncompressed bytes, never fewer.** The reader locates flow
  offset N by dividing by that size, so a short record drifts every index after it. Octavo did
  ship records shortened to UTF-8 character boundaries once: a Cyrillic book rendered from the
  middle of a tag (`div>` visible on screen) and could not be paged, while an ASCII book looked
  fine. `RecordSizeInvariantTests` runs the same assertions over calibre's files and ours.
- **The extra-record-data flags live in the low half of the word at `0xE0`, and must agree with
  what `textRecords` actually appends.** Bit 0 is the multibyte-overlap trailer: when a character
  straddles the end of a record, that record repeats the *next* record's leading continuation
  bytes, then a count byte. Bit 1 is a trailing byte sequence, which neither writer emits — TBS
  feeds the progress machinery, not rendering. Claiming trailers that are absent eats content;
  omitting the claim for trailers that are present feeds the reader garbage.
- **MOBI 6 output changed with the AZW3 work and has not been checked on the device since.**
  It shares `MOBIRecord0`, so the record-size, extra-data-flags and FCIS fixes apply to it too.
  The new bytes are strictly better formed than what shipped before — the old writer claimed
  trailers it never wrote — but "better formed" is not "verified". Check it on the Kindle before
  relying on it as the fallback.
- **`fcisRecord` is 52 bytes.** It was 44 for a long time — two fields short, one constant wrong
  — which no Mac-side check notices.
- The device is jailbroken with dead leftovers (`jb.sh`, `patchedUks.sqsh`, `mesquito/`) — the OTA to
  5.19.5 killed the exploit, so KOReader is not an option.

## Device safety rules

Enforced in code, not by convention — keep them that way:

- Writes go **only** under the `documents/` handle. `*.bin` in the storage root is what the Kindle
  treats as a firmware update.
- `.sdr` folders (reading progress, annotations, highlights) are never deleted; orphan detection
  skips folders entirely, and book removal is only ever an explicit user action. The app's
  "Remove from device" goes through `DeviceController.remove(bookUUIDs:)`, which resolves filenames
  from the manifest and deletes via `delete(filename:)` — and that only ever matches non-folder
  entries, which is what keeps the `.sdr` sidecars safe.
- `octavo-sync --apply` pulls all of `documents/` to `~/Library/Application Support/Octavo/device-backup`
  before its first write; `CalibreLibraryStore.backup` copies `metadata.db` before the first edit.

## Testing

Tests run against the **real calibre library and the real device corpus** rather than fixtures: 28
EPUB, 30 AZW3, 13 CBZ, one FB2 and one PDF. Read tests work on a temp copy of `metadata.db` — never
point a test at `~/Calibre Library` itself — and bail out silently (`return`) when the library is
absent, so the suite still passes on another machine.

The *writing* library tests build their own library with `CalibreLibraryStore.create` instead, which
is both the from-scratch coverage and the reason they need nothing on the machine. `add(fileAt:)`
never parses the file it imports, so a few bytes named `sample.epub` are a valid import source.
`createsLibraryFromScratch` is the test that would catch a broken embedded schema: it asserts
`user_version`, the `library_id` row, and a `sort`/`uuid` filled in by the insert trigger.

Three tests in `MetadataFetchTests` hit the network, and all three are gated on the
`.requiresNetwork` condition trait (`OCTAVO_NETWORK_TESTS=1`) rather than on a `--skip` regex in CI —
SwiftPM cannot filter by tag, and a name-based skip list silently lapses when a test is renamed.
Any new test that reaches a catalogue needs that trait. Assertions must be specific enough to catch real
breakage: earlier corpus tests only checked "cover is non-nil" and "title differs from the filename",
which let a wrong codepage offset (mojibake Cyrillic) and a wrong image offset (text records
returned as covers) pass unnoticed. Cover checks now require JPEG/PNG magic.

Device-facing changes ultimately need a human to look at the Kindle screen — that is the only oracle
for "does this book actually open".

## Not implemented yet

Embedded EPUB fonts (dropped, the Kindle substitutes), nested NCX (the index is written flat),
`filepos` internal links in MOBI 6 output (AZW3 gets `kindle:pos:` ones), `.apnx` page numbers.
