# Changelog

## 0.3.1 — 2026-09-28

- Fixed a crash when the mouse moved while the selection overlay faded out.
- An area capture keeps only its own pixels. Before, it held on to the whole frozen
  screenshot (20 MB for a 3440×1440 display) for as long as the thumbnail, editor or pin
  lived: 20 captures now leave Glint at 36 MB instead of 178 MB.
- All displays are captured at once when the overlay opens, instead of one by one.

## 0.3.0 — 2026-09-27

- The default shortcuts are the macOS ones: ⇧⌘3 full screen, ⇧⌘4 area, ⇧⌘5 record.
  The other captures keep ⌃⇧. Existing custom shortcuts are left alone.
- ⇧⌘4 does area and window in one: the window under the cursor is highlighted, a click
  takes that window on its own (uncovered, with shadow and transparent corners), a drag
  takes an area. Before, a click cropped the window from the frozen screenshot.
- Motion throughout, on one shared timing so it all moves alike, and plain fades with
  Reduce Motion on:
  - a capture shrinks from where it was taken into its thumbnail;
  - thumbnails slide in from the screen edge, make room for each other, and leave over
    the edge; a two-finger swipe toward the edge dismisses one;
  - the selection dim eases in, the window highlight glides from window to window, and
    the hints sit in a blurred HUD pill;
  - toasts pop in like the volume HUD; pins pop in and shrink away;
  - the editor's tool highlight slides to the chosen tool, also from the keyboard;
  - the recording HUD slides in and its dot breathes.
- Quick access buttons are glass (system materials) and give when pressed.
- Settings → Shortcuts flags a shortcut that macOS's own screenshot shortcuts still
  own, with a button to Keyboard Shortcuts. Carbon registers it without complaint but
  macOS gets the keys first.

## 0.2.2 — 2026-09-24

- The window shadow falls below the window, like macOS's own, instead of above it and
  cut off at the top edge. Backdrop shadows had the same flip.
- JPEG exports flatten transparency onto white: window captures no longer get a black frame.
- A backdrop in the editor replaces the window shadow instead of stacking a second one.
- Window captures keep their color space (Display P3 stays P3).
- In area mode a click on a window crops it from the frozen screenshot, so it's exactly
  what you saw, lands on the right display and counts as the previous area.
- Window mode picks on press, so releasing on another display can't pick the wrong window.
- A Screen Recording grant that lands while Glint is running now counts right away. Before,
  the shortcut kept opening System Settings until Glint was restarted.

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
