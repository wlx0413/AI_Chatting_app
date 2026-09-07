# Newsreader SC — optional imported serif font

This folder contains the merged **Newsreader SC** fonts (Newsreader Latin glyphs
+ macOS Songti SC CJK glyphs, one font per weight, family name `Newsreader SC`).
They are **NOT bundled** into the app to keep it small.

## How to use (import once)

1. Settings (⌘,) → Appearance → Font (字体预设) → **Import Serif Font…**
2. Select the three files in this folder: `NewsreaderSC-Regular.ttf`,
   `NewsreaderSC-Bold.ttf`, `NewsreaderSC-Italic.ttf` (multi-select works).
3. Pick **Serif (衬线)** as the font preset — Latin renders in Newsreader and
   Chinese in Songti, from the same font, with zero system fallback.

The files are copied to `~/Library/Application Support/AIChatApp/Fonts` and
registered automatically at launch. Without an import, the built-in serif stays
system New York + Songti SC cascade (no extra bytes in the app bundle).

## Rebuilding the merged font (advanced)

`prep_all.py` (kept locally at `/tmp/mx` by the author) runs `fontTools
pyftmerge` against the OFL Newsreader variable font and `/System/Library/Fonts/
Supplemental/Songti.ttc` (Songti scaled 1000→2000 upem), then renames the family
to `Newsreader SC`.

## License

- Newsreader: SIL Open Font License 1.1 — redistribution of derivatives allowed.
- Songti SC: Apple system font — merging/extraction is for **personal local
  use only**; the merged fonts must **not** be redistributed or shipped in the
  app bundle.
