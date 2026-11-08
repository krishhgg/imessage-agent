# Golden output

This folder holds the text captured from `bench/renderers/ours.py` on the fixture, the record JSON that `IMCoreTests` decodes, and the capture command. Tests reach it through `Fixture.goldenDir`. It sits outside every target folder, so SwiftPM ignores it and adding a file never changes `Package.swift`.

## Capture

Run this from the repo root:

```
python3 -I Tests/Fixtures/golden/capture.py
```

It uses only the standard library, `bench/reader.py` and `bench/renderers/ours.py`, and reads only `Tests/Fixtures/chat.db`, `manifest.json` and `contacts.json` next to it. For each case it writes `<case>.txt`, the exact bytes `ours.py` prints, and `<case>.json`, the page record from `Sources/IMCore/Pages.swift`. `cases.json` lists every case with its command and verb. A second run writes the same bytes.

## What is compared

`GoldenTests.testEveryCaseMatchesOursByteForByte` renders every record with `Format` and compares bytes, not Swift strings, because Swift treats NFC and NFD text as equal.

Only the success output of `chats`, `unread`, `read`, `show` and `who` is captured from `ours.py`. For `search`, `send`, `react`, `unsend`, `edit`, `att` and every error line, `ours.py` disagrees with DESIGN.md, so those expectations are written by hand from DESIGN.md and `Sources/IMCore/Results.swift`. `Sources/IMCore/Format.swift` lists the differences.

One case is not compared byte for byte. For `read-12-n200`, `ours.py` prints 253 lines, past the 200-line output cap. `Format` keeps the newest messages that fit and adds a `more: imessage read 12 --before <rowid>` footer. `GoldenTests.testReadOverTheLineCapKeepsTheNewestSuffix` checks that the kept message lines are exactly the last lines `ours.py` prints.

`ours.py` prints no footer for newer messages. When `ReadService` builds a `read --after` or `read --around` page from the fixture and the chat has newer visible rows, the expected text is the captured text plus `more: imessage read <chat> --after <rowid>` (`Golden.expectedText`). The captured files stay as `ours.py` wrote them.

`Tests/Fixtures/build.sh` doesn't touch this folder.
