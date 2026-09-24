<p align="center">
  <img src="docs/icon.png" width="128" alt="Glint icon">
</p>

<h1 align="center">Glint</h1>

<p align="center">
  <b>A free, open-source screenshot tool for macOS that blurs your secrets before you share them.</b><br>
  Capture, annotate, pin, and copy text. Emails, IBANs, card numbers and API keys get pixelated in one click, on-device.
</p>

<p align="center">
  <img src="docs/redact.png" width="720" alt="Glint editor after one click on Redact: email, phone, IBAN, card number, API key and IP address are pixelated; name and plan are untouched">
</p>

---

## Why

Every screenshot you drop into Slack, a GitHub issue or a support ticket is a small data
leak waiting to happen: a customer's email in the corner, an API key in a terminal, an
IBAN on an invoice. Blurring them by hand is tedious, so people don't.

Glint finds them for you. It reads the screenshot with Apple's on-device text recognition,
checks each match (IBANs and card numbers must pass their checksum, so an order number or
a timestamp doesn't get blurred), and pixelates it. Each redaction is an ordinary
annotation: move it, delete it, or add more.

## Features

**Capture**
- **Area**: freezes the screen first, so menus and hover states stay put. Crosshair,
  8× loupe with pixel coordinates and hex color, and a live size readout in pixels.
- **Window**: the window on its own, even when something covers it, with its shadow and
  transparent corners. Press <kbd>Space</kbd> during an area capture to switch.
- **Full screen** and **previous area** (the same rectangle again, for before/after shots).
- **Text (OCR)**: drag over anything and the text lands on your clipboard.

**After capture**
- **Quick access overlay**: a thumbnail in the corner. Drag it into any app, or hover to
  copy, save, annotate, pin, copy its text or redact it.
- Copies to the clipboard and saves to `~/Pictures/Glint`. Both can be turned off.
- **Pin to screen**: a floating, always-on-top copy. Drag to move, pinch to resize,
  scroll to fade, double-click to close.

**Annotate**

<p align="center">
  <img src="docs/editor.png" width="720" alt="Glint editor with an arrow, numbered steps and a rectangle">
</p>

- Arrow, rectangle, ellipse, line, pen, highlighter, text, numbered steps, pixelate,
  black-out and crop, each with a single-key shortcut (<kbd>A</kbd>, <kbd>R</kbd>, <kbd>O</kbd>…).
- Tapered arrows and soft shadows, so annotations look good without fiddling.
- Select, move (arrow keys nudge), recolor and delete. Unlimited undo and redo.
- **Backgrounds**: a gradient frame with rounded corners and a shadow, for posts and docs.
- Retina-aware: files carry the right DPI, so a 2× shot shows at its real size in
  Keynote, Pages and Preview.

**Private by design**: no account, no network access, no analytics. OCR and redaction
run on your Mac.

## Shortcuts

| Action | Shortcut |
| --- | --- |
| Capture area | <kbd>⌃⇧4</kbd> |
| Capture window | <kbd>⌃⇧5</kbd> |
| Capture full screen | <kbd>⌃⇧3</kbd> |
| Capture previous area | <kbd>⌃⇧6</kbd> |
| Capture text (OCR) | <kbd>⌃⇧2</kbd> |

While selecting: <kbd>Space</kbd> switches between area and window mode, <kbd>⏎</kbd> takes
the whole screen, <kbd>Esc</kbd> cancels.

In the editor: <kbd>⌘Z</kbd> / <kbd>⇧⌘Z</kbd> undo and redo, <kbd>⌘C</kbd> copies,
<kbd>⌘S</kbd> saves, <kbd>⌘⏎</kbd> finishes, <kbd>⌫</kbd> deletes the selection.

## Glint vs. CleanShot X

CleanShot X is excellent and does more. Here's where each one stands today:

| | Glint | CleanShot X |
| --- | --- | --- |
| Price | Free, MIT | Paid license |
| Area, window, full screen, previous area | ✓ | ✓ |
| Frozen screen while selecting, loupe | ✓ | ✓ |
| Quick access overlay, drag & drop | ✓ | ✓ |
| Annotate, numbered steps, pixelate, crop | ✓ | ✓ |
| Background frames | ✓ | ✓ |
| OCR, pin to screen | ✓ | ✓ |
| **Automatic redaction of emails, IBANs, cards, keys, tokens** | ✓ | – |
| Scrolling capture | – ([roadmap](#roadmap)) | ✓ |
| Screen recording, GIF | – ([roadmap](#roadmap)) | ✓ |
| Cloud upload & share links | – | ✓ |
| Custom shortcuts | – ([roadmap](#roadmap)) | ✓ |

## Install

Download `Glint.zip` from the [latest release](../../releases/latest), unzip, and move
`Glint.app` to `/Applications`. Requires macOS 14 Sonoma or later. Universal binary.

Glint isn't notarized yet, so macOS blocks the first launch. Right-click → **Open**, or:

```sh
xattr -dr com.apple.quarantine /Applications/Glint.app
```

On first capture macOS asks for **Screen Recording** permission. Allow it in System
Settings → Privacy & Security → Screen & System Audio Recording, then reopen Glint.

### Build from source

Only the Xcode Command Line Tools are needed, no full Xcode.

```sh
git clone https://github.com/brentc22/glint.git
cd glint
scripts/make-signing-cert.sh   # once: a stable local identity keeps the permission across rebuilds
make run                       # build, install to /Applications, launch
```

## How it works

| Piece | How |
| --- | --- |
| Capture | ScreenCaptureKit (`SCScreenshotManager`), all displays at native resolution, before the overlay appears |
| Window capture | `SCContentFilter(desktopIndependentWindow:)`, z-order from `CGWindowList` |
| Shortcuts | Carbon `RegisterEventHotKey`, which needs no Accessibility permission |
| OCR & redaction | Vision `VNRecognizeTextRequest` (language correction off, so keys stay intact), regex + IBAN mod-97 + Luhn, per-match boxes via `boundingBox(for:)` |
| Pixelate | exact block averages, not resampling, which would keep a real pixel per block |
| Rendering | one Core Graphics renderer, used by both the editor canvas and the export |

## Development

```sh
make test                                         # 22 tests: matcher, renderer, undo, OCR on a real image
make bundle                                       # Glint.app in the repo root
open Glint.app --args --edit docs/demo-input.png  # editor on the demo image, no permission needed
```

`docs/demo-input.png` is a made-up settings screen full of fake sensitive data
(`swift scripts/make-demo-image.swift` regenerates it). The test suite checks that Redact
finds exactly its six secrets and leaves the rest alone.

Other launch arguments: `--quick-access <image>` and `--select-demo <image>` (the selection
overlay over an image instead of your screen).

```
Sources/
  GlintCore/    annotations, renderer, redaction, OCR, undo; no AppKit, fully tested
  Glint/        the menu bar app: capture, overlay, editor, pin, settings
  GlintTests/   tests (a plain executable; XCTest needs full Xcode)
```

## Roadmap

- [ ] Scrolling capture
- [ ] Screen recording to MP4 and GIF
- [ ] Custom shortcuts
- [ ] Self-timer, hide desktop icons while capturing
- [ ] Redaction rules you can extend (your own patterns, names, customer IDs)
- [ ] Notarized builds and a Homebrew cask

Ideas and PRs welcome. Open an issue first for anything big.

## License

[MIT](LICENSE)
