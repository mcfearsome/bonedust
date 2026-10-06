# Fonts

Two bundled faces in three files, all SIL OFL-1.1. The licence only requires that
the fonts themselves stay OFL and are not sold on their own, so shipping them in a
paid app is fine. Each family's licence text is kept beside its files
(`OFL-RubikDirt.txt`, `OFL-CourierPrime.txt`); keep them together if a file moves.

| File | Used by | Role |
|---|---|---|
| `RubikDirt-Regular.ttf` | `Typography.display`, `Typography.label` | Wordmark, large headings, small-caps field labels |
| `CourierPrime-Regular.ttf` | `Typography.number` | Every number that changes while you watch it |
| `CourierPrime-Bold.ttf` | `Typography.number` at semibold and heavier | The same numbers when they need weight: the real Bold outlines, not a smeared Regular |

Body text is SF Pro via `Typography.ui` and is deliberately not a custom face:
it gets Dynamic Type right for free, and a notebook's body text should be
neutral. The character lives in the display face and the numerals.

## Adding or replacing a face

1. Put the `.ttf` in this directory, with its OFL text file beside it.
2. List it under `UIAppFonts` in the `Bonedust` target's `info.properties` in
   `ios/project.yml`.
3. Run `xcodegen generate`.
4. Point the matching constant in `UI/DesignTokens.swift` at the PostScript name
   (`Typography.displayFace`, `Typography.numberFace` or `Typography.numberBoldFace`).

`FontRegistrationTests` fails loudly if a face is missing, so you will know.

## Fallbacks

Every `Typography` accessor falls back to the system face it used before these
fonts existed — SF Pro Black Expanded for display, SF Mono for numerals. A
missing file changes how the app looks; it never blanks a label or crashes.
