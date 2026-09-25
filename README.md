# Plakke

**Hold ⌥, tap V, release to paste.** A ⌘Tab-style clipboard switcher for macOS.

Plakke (Frisian for *paste*) keeps your last 10 clips and lets you flick through them with one hand, the same
way you flick between apps. Local only — no sync, no accounts, no network.

```
 ┌───────┐ ┌───────┐ ┌═══════┐ ┌───────┐ ┌───────┐
 │ Link  │ │ Code  │ ║ Text  ║ │ Image │ │ Color │   ← frosted strip, centered on screen
 │ ...   │ │ ...   │ ║ ...   ║ │ ...   │ │ #4F8E │     selected card lifts and glows
 └───────┘ └───────┘ └═══════┘ └───────┘ └───────┘
      release ⌥ paste · ⇧ plain text · 1–9 0 jump · ⌫ remove · esc
```

## The switcher

| While holding ⌥ | |
|---|---|
| tap **V** | next clip (first tap lands on the *previous* clip, like ⌘Tab) |
| **⇧ V** / **←** | previous clip |
| **1 – 9**, **0** | jump straight to that slot (**0** is slot 10) |
| **↑ / ↓** | on an image with recognised text: flip the card between **image** and **text** (what's showing is what pastes) |
| **space** | **peek** — full-size preview of the highlighted clip (tap again to close) |
| **P** | **pin / unpin** the highlighted clip |
| **U** / **L** / **T** / **R** / **M** | arm **transforms**: UPPERCASE, lowercase, Tidy whitespace, Reflow paragraphs, Markdown. They stack: value conversion first, then structure (Reflow, Tidy), then case, then Markdown, whatever order you press them; tap again to disarm one |
| **C** / **J** | on a colour: swap `#hex` ⇄ `rgb()`. On JSON: pretty-print ⇄ minify. Only offered when the clip is actually one of those |
| **X** | on an image: **crop**. Runs an edge scan and starts from the content it finds; drag the handles to adjust |
| **⌫** | remove the highlighted clip from the strip |
| **⌘Z** | put back the clip you just removed (while the strip is up) |
| **⏎** | paste straight away, without releasing ⌥ (in crop mode: **⏎** pastes, **X** goes back to the full image, **esc** cancels) |
| **esc** | cancel |
| release **⌥** | paste the highlighted clip (with the armed transform, if any) |
| release **⌥ while holding ⇧** | paste as plain text (also forces OCR text for images) |

Pasting moves the clip to the front of the strip, so the thing you just used is one tap away next time.

## What makes it nice

- **Type-aware cards.** Plakke classifies every clip: text, code (monospaced preview), links
  (domain in bold, URL underneath), colors (`#hex` renders as a live swatch), images
  (thumbnail), and files (icons + names).
- **Accent glow.** Each type has its own color; the selected card scales up with a spring and
  glows in that color, so you can tell what you're about to paste from across the room.
- **Source app badge.** Every card shows the icon of the app you copied it from.
- **Relative timestamps.** "12 sec. ago" beats guessing.
- **Frosted glass.** `ultraThinMaterial` panel that adapts to light and dark mode, floats above
  full-screen apps and every Space, and never steals focus from the app you're pasting into.
- **Handles secrets properly.** A copy flagged as concealed by a password manager, or coming from a
  known one (1Password, Bitwarden, Apple Passwords, KeePassXC, LastPass, Dashlane…), becomes a
  *secret*: it lives in memory only, never touches the history file (which is itself owner-only and
  excluded from backups), shows blurred with a lock and a
  60-second countdown, can't be pinned, and vanishes when the timer ends. If the source app clears
  the clipboard sooner (KeePassXC does), Plakke drops it at that moment. Pasting a secret re-flags it
  as concealed so other clipboard tools ignore it too. One menu toggle turns this into "ignore
  secrets entirely" if you prefer. Anything *shaped* like a credential gets the same treatment even
  when no app flags it: JWTs, AWS/GitHub/Slack/Stripe/Google keys, private-key blocks, and card
  numbers that carry a real issuer prefix at that issuer's length and pass the Luhn check. The
  patterns are deliberately narrow — a git SHA, an IMEI or a long order number stays an ordinary clip.
  Recognised text from an image is screened the same way, so a screenshot of a token isn't written to
  the history file either.
- **Privacy.** **Pause Recording** stops capture until you turn it back on (the menu-bar icon dims so
  you can't forget), **Never Record From** ignores a chosen app and forgets what it already left
  behind, and **Forget Clips After** drops unpinned clips older than 1, 8 or 24 hours. Clips an app
  generates itself, or marks transient, are never recorded at all.
- **Crop.** **X** on an image opens a crop editor inside peek. It scans the edges first — trimming
  transparent window shadows and uniform borders like letterboxing or a white page margin — and
  starts the rectangle at whatever it found, so the common case needs no aiming at all. Drag the
  corners or edges to adjust, with rule-of-thirds guides and a live pixel readout. Pressing **X**
  latches the session: you can let go of ⌥ and use both hands, then **⏎** pastes and **esc** cancels.
  The crop applies to the full-resolution original at paste time; the stored file is never touched,
  so the same clip still pastes whole later. On a photo, where there's no border to find, the
  rectangle just starts at the full image.
- **Peek.** Space opens a big preview above the strip: full text, the whole image, every file.
  The preview shows the transformed text if a transform is armed, so you see exactly what will land.
- **Pinned clips.** Pins live to the right of a thin divider and never fall off the strip. Clear
  History leaves them alone. ⌥-click a clip in the menu bar to pin it from there too.
- **Transforms.** Arm one with a single key, watch the peek update, release to paste. The hint row
  only offers the keys that apply to the clip you're on. Markdown is
  type-aware: links become `[host](url)`, code gets fenced, prose becomes a blockquote. **Reflow**
  turns hard-wrapped scans, OCR output and quoted emails back into real paragraphs — the natural
  companion to ↓ on an image.
- **OCR.** Every image is run through Vision in the background. A small viewfinder badge appears
  on the card when text was found; press ↓ to flip the card to its text (↑ flips back), and release
  to paste whatever is showing. Transforms work on the text too.
- **Stays fast.** Cards render a short preview, not the clip; text is capped at 1 MB, rich forms at
  256 KB; images are re-encoded off the main thread; classification only scans the first 64 KB; history
  is written asynchronously and coalesced. A very large paste costs one read, not a stalled strip.
- **Slides, never overflows.** When recents plus pins won't fit the screen, the strip shows a window
  that follows the selection, with `‹ 3` / `4 ›` counters at the edges.
- **Accessible by default.** Reduce Transparency swaps the glass for an opaque panel; Reduce Motion
  drops the spring and the fades; VoiceOver hears every selection announced ("Link, example.com,
  3 of 10, pinned"). Type accents are tuned per appearance so they clear 4.5:1 in both light and
  dark, and **Larger Cards** scales the whole strip by 25%.
- **Nearly zero config.** The menu bar holds your clips, then the things you *do* — pause, clear
  history, change the hotkey — and a single **Settings** submenu for the five things you can *set*,
  with Reset to Defaults at the bottom. Every setting is declared once in `Settings.swift`; the menu
  is built from that list rather than hand-assembled, so the two can't drift apart.

## Build & run

Requires macOS 14+ and Xcode 15+ (for the Swift toolchain).

```sh
make run          # swift build → assemble Plakke.app → open it
```

On first launch macOS asks for **Accessibility** access (needed to watch the ⌥ key and to send ⌘V).
Flip the switch in System Settings → Privacy & Security → Accessibility and Plakke picks it up
automatically — no relaunch needed.

> **Tip:** ad-hoc signatures (`make` default) change on every rebuild, which makes macOS forget the
> Accessibility grant. If you iterate a lot, sign with a stable identity:
> `make SIGN_ID="Apple Development: you@example.com"`

You can also `open Package.swift` in Xcode, but you'll still want the Makefile to wrap the
binary in an `.app` bundle with `Info.plist` (that's what makes it a menu-bar-only app).

## Layout

```
Sources/Plakke/
  main.swift              NSApplication bootstrap (accessory = no Dock icon)
  AppDelegate.swift       wires everything together
  Hotkey.swift            the trigger combo (persisted via Settings) + keycodes
  HotkeyRecorder.swift    the "press a new combo" window
  HotkeyController.swift  CGEventTap state machine: idle → cycling → commit/cancel
  ClipboardWatcher.swift  polls NSPasteboard.changeCount, captures clips
  ClipItem.swift          model + type classification (text/code/url/color/image/file)
  ClipStore.swift         10-item ring, JSON + PNG persistence in ~/Library/Application Support/Plakke
  Paster.swift            writes the clip back (or a transform of it) and synthesizes ⌘V
  Transform.swift         U/L/T/R/M/C/J paste-time transforms (incl. paragraph reflow)
  OCR.swift               Vision text recognition for image clips
  SwitcherController.swift  non-activating NSPanel + selection state
  SwitcherView.swift      the SwiftUI strip and cards
  StatusBarController.swift  menu bar item
  AboutController.swift   the About panel
  Permissions.swift       Accessibility prompt + polling
  Settings.swift          every setting declared once: key, default, label, help text
  Sensitive.swift         credential shapes that become secrets without being flagged
  Formats.swift           hex ⇄ rgb() and JSON pretty ⇄ minify, for the C and J transforms
  EdgeScan.swift          finds the content rectangle: transparency pass, then uniform colour
  ImageCrop.swift         the crop as a fraction of the image, so preview and paste agree
  CropEditor.swift        the AppKit crop surface — handles, guides, pixel readout
  TextLines.swift         Unicode-aware line splitting + size caps, shared by the above
  Scheduling.swift        timers that keep firing while a menu is open
Resources/AppIcon.icns    generated app icon (source: AppIcon-1024.png)
```

## Changing the hotkey

Menu bar icon → **Change Hotkey…**, then press the combination you want. ⌃ and/or ⌥ plus any
key; ⌘ and ⇧ are refused (⌘ collides with real shortcuts, ⇧ is used inside the switcher), and so are
the keys the switcher itself uses — the digits, the arrows, space, ⏎, ⌫, and P, U, L, T, R, M, C, J, X
and Z. If a saved combo later becomes one of those, Plakke falls back to ⌥V rather than colliding
with it.

© 2026 iappyx · MIT License, see `LICENSE`.
