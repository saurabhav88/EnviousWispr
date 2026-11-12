# EnviousWispr Screen Atlas

What the macOS app looks like, as pictures and as HTML parts you can copy. Use it before you build, describe or mock up any EnviousWispr screen, so the logo, the pills and the Settings parts are the real ones and not invented.

`DESIGN.md` at the repo root owns the rules, tokens and Swift parts. This folder shows them.

## What is here

| Path | What it is |
|---|---|
| `index.html` | The gallery. Open it in a browser straight from disk. It shows each HTML part next to its app picture, every picture by group, a search box and a light/dark switch. |
| `starter.html` | A complete mockup page to copy: it links `atlas.css` and shows where parts go. |
| `inventory.md` | One section per picture: what it shows, the sections, rows, controls and button names. Search it with grep. |
| `pictures/` | `<id>-light.png` and `<id>-dark.png` for every picture in `atlas.json`, at 1x. |
| `atlas.css` | CSS variables generated from the `DESIGN.md` values block, then the part classes. |
| `parts/*.html` | Copy-ready HTML parts, each between `<!-- part: ... -->` and `<!-- /part -->`. |
| `logos/` | SVG brand marks translated from their Swift owners (each file names its owner). |
| `atlas.json` | The list of pictures: id, title, group, and how each one is made. |

## Build a mockup from it

1. Copy `starter.html`. It links the whole `atlas.css` (variables and part classes; the parts need both) and shows two parts in place. Paths in the parts are relative to the page, so keep the copy next to `atlas.css` and `logos/`: save it inside `design/atlas/`, or copy `atlas.css` and `logos/` into the copy's folder.
2. Copy parts from `parts/*.html` (or the "Copy snippet" button in `index.html`) into the starter. Change the words, not the look.
3. Use the logo files in `logos/`. The EnviousMeet mark is a picture (`pictures/logo-envious-meet-*.png`): it is Apple's `person.2.wave.2` symbol in the rainbow, so it is not redrawn as SVG.
4. For a pill notice with no HTML part, paste its picture: `<img src="pictures/notice-<id>-dark.png" alt="">`, with the id from `inventory.md` "Pill notices". The sentences come from `DictationNarrator`; do not invent new ones.
5. For a whole screen, start from its page picture and `inventory.md` section. A Settings page sits in the window frame (`hand-window-dictation`): the sidebar card on the left, the page card on the right.
6. SF Symbols do not exist in a browser. Where a part needs an icon, use a close stand-in and name the SF Symbol from `DESIGN.md` "Icons" in your mockup notes.
7. The pill HTML parts are approximations. Where the exact pill matters, use its picture.

Light and dark: the parts follow the system appearance, or `data-theme="light"` / `data-theme="dark"` on `<html>`.

## What the atlas does not show

It shows all three pill designs with their recording, locked, words and notice states, and one picture per distinct notice look (the other notice reasons reuse a look with other words). It does not show:

- Onboarding: it is being rebuilt; its pictures come after that change.
- History with a dictation or a meeting selected, the meeting detail view and playback: the photo test cannot set them up yet.
- Sheets and pop-ups opened from a page (editors, the language installer, help bubbles open).
- The menu bar menu in light mode.

For these, read the Swift view named in `DESIGN.md` or `inventory.md`. Never guess the look.

## Where the pictures come from

- **Photo test pictures** (`"kind": "harness"`): `DesignRenderHarness` draws the real SwiftUI views offscreen with fixed fixtures (`Tests/EnviousWisprTests/Design/`). Pages are drawn at the 820pt window (578pt page area) and show the whole page, top to bottom.
- **Hand photos** (`"kind": "hand"`): screens the photo test cannot set up (the History page, the full window with its sidebar, the menu bar menu), photographed from the running dev app. Refresh them by hand.

If a picture and the running app disagree, the app wins. Refresh the pictures.

## Refresh

After a visible UI change:

```bash
TEST_RUNNER_EW_RENDER_ATLAS=1 scripts/xcode-test.sh --host local --filter EnviousWisprTests/DesignAtlasRender
```

It rewrites only the photo test pictures. Then update the matching `inventory.md` sections and run:

```bash
python3 scripts/design/build-atlas-index.py
```

After a `DESIGN.md` values change, `python3 scripts/design/generate-tokens.py` rewrites both the Swift tokens and the generated part of `atlas.css`.

`DesignAtlasSyncTests` fails when `atlas.css` and `DESIGN.md` disagree, when a part class uses a raw color, when a listed picture or its inventory section is missing, or when `index.html` is out of date. A picture that is slightly older than the app does not fail anything.
