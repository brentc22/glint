# Changelog

## 0.2.2 — 2026-09-24

- The window shadow falls below the window, like macOS's own, instead of above it and
  cut off at the top edge. Backdrop shadows had the same flip.
- JPEG exports flatten transparency onto white: window captures no longer get a black frame.
- A backdrop in the editor replaces the window shadow instead of stacking a second one.
- Window captures keep their color space (Display P3 stays P3).
- In area mode a click on a window crops it from the frozen screenshot, so it's exactly
  what you saw, lands on the right display and counts as the previous area.
- Window mode picks on press, so releasing on another display can't pick the wrong window.

## 0.2.1 — 2026-09-24

- Window capture picks the window at the click position. Before, a click without a
  prior mouse move (or on another display) fell back to the whole screen.
- The window under the cursor is highlighted as soon as the overlay opens.
- In window mode a click on the empty desktop does nothing instead of capturing it all.
- Invisible helper windows are no longer pickable.
- Window captures get a macOS-style shadow (Settings → Capture to turn it off).

## 0.2.0 — 2026-09-24

Driven by what people ask for most in screenshot tools (GitHub issues, reviews, Reddit).

- Scrolling capture, with sticky header/footer and floating-element handling
- Screen recording to MP4, with GIF export
- Custom shortcuts (layout-aware, so AZERTY/QWERTZ show the right keys)
- Self-timer, color picker in the selection overlay, QR code scanning
- Optionally include the mouse pointer
- Settings rebuilt as six tabs; quick access position and duration, open the editor
  directly, PNG or JPEG, Retina at 1×, file name prefix
- Redaction: choose which kinds to find, add your own terms or regular expressions
- OCR joins pieces of one line and reads tall images in tiles
- Annotate an image from the clipboard
- New logo and menu bar icon
- `--self-test`: every capture path, end to end

## 0.1.0 — 2026-09-24

First release.

- Capture area (frozen screen, loupe, pixel size), window, full screen, previous area
- Capture text (OCR) to the clipboard
- Quick access overlay with drag & drop, copy, save, annotate, pin, redact
- Editor: arrow, rectangle, ellipse, line, pen, highlighter, text, numbered steps,
  pixelate, black-out, crop; select, move, recolor, undo/redo; gradient backgrounds
- One-click redaction of emails, phone numbers, IBANs, card numbers, API keys, JWTs and
  IP addresses, on-device
- Pin screenshots to the screen
- Settings: after-capture actions, save folder, launch at login
