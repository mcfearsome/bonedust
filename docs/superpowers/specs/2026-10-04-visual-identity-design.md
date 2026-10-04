# Bonedust Visual Identity — Field Notebook

**Date:** 2026-10-04
**Status:** Approved design, pending implementation plan

## Problem

The design reads as generic. The written direction in `DesignTokens.swift`
(field geology, museum specimen labels, survey orange) is sound, but the
execution is four defaults:

1. **No custom type.** `Typography.display` resolves to SF Pro Black Expanded.
   `Resources/Fonts/` contains only a README. Type carries most of a mobile
   app's identity; the system face guarantees it looks like every other app.
2. **Dark neutral plus one orange accent** is the most-used app palette of the
   last five years. `ground #221813` to `raised #2E201A` is a 6% lightness
   step, which reads as flat dark gray in daylight.
3. **No texture.** `cardRadius: 4`, `hairline: 1`, a 3/3 dash. A game about
   dirt and dust rendered in clean vector chrome.
4. **Two unrelated worlds.** The slab is a nearest-filtered pixel texture with
   real character. The chrome around it is smooth SwiftUI. Nothing bridges them.

## Intent

Give the app one legible identity: **a specimen on a field-notebook page.**

- **Who it is for:** players of the dig loop, on a phone, in varied light.
- **Success:** a screenshot is recognisable as Bonedust with the wordmark
  cropped out.
- **Non-goals:** no new game mechanics, no layout restructuring, no change to
  simulation or economy behaviour. This is colour, type, texture, and chrome.

## Design

### 1. Invert the page

The ground goes from dark umber to cream stock. The slab becomes the only dark
object on screen, so every screen reads as a specimen on a page rather than a
game inside a dark shell.

### 2. One ramp, two ends

`Ink` and `SlabPalette` are currently independent sources of truth. Both derive
from a single nine-stop warm ramp. Chrome takes the light end, dirt takes the
dark end, the accent is shared.

The ramp lives in `BonedustCore` as plain values (no SwiftUI import) so it is
covered by the existing test target.

| Stop | Hex | Role |
|---|---|---|
| `earth0` | `#F6EFDE` | Pasted-label / raised surface |
| `earth1` | `#EDE4CF` | Page — the ground |
| `earth2` | `#DFD4BB` | Ruled box fill |
| `earth3` | `#C4B596` | Grid, dividers, hairlines |
| `earth4` | `#9C8A6E` | Hairlines, disabled state, decorative. **Never text.** |
| `earth5` | `#6E5E48` | Secondary text; slab topsoil |
| `earth6` | `#4A3D2E` | Slab matrix, mid |
| `earth7` | `#2E2619` | Slab matrix, dark |
| `earth8` | `#1C1A17` | Ink — primary text, deepest matrix |

Accents, all retuned for a light ground:

| Token | Hex | Meaning |
|---|---|---|
| `stamp` | `#B03A2B` | The single accent. See §5. |
| `gem` | `#176574` | Gems only. Darkened from `#56B8C8`, which is both too weak and below AA on cream. |
| `safe` | `#41642F` | Speed and intact semantics only. Darkened from `#7FBF6A`, same reason. |

**Bone against page.** Bone ivory `#F1E7D3` is within 3% of the page colour, so
a fully-excavated slab would bleed into the background at its edges. Two fixes,
both required: bone moves to `#FDFAF2` (brighter and cooler than the page), and
the slab gets a hard `earth8` border two *texture* pixels wide, so it scales
with the pixel art instead of hairlining out on a large display.

### 3. Type

Three faces, each with one job. Two are new.

| Role | Now | Proposed | Licence |
|---|---|---|---|
| Display, wordmark, labels | SF Pro Black Expanded | Bebas Neue | SIL OFL |
| Numerals | SF Mono | Courier Prime | SIL OFL |
| Body and controls | SF Pro | SF Pro (unchanged) | system |

Body stays on SF Pro deliberately: it gets Dynamic Type right for free, and a
notebook's body text being neutral is correct. The character lives in the
display face and the numerals.

Both new faces are SIL OFL, so they can be committed to the repo. Bebas Neue is
the safe pick for stamped condensed caps; because it is referenced through a
single constant, a rougher letterpress face can be swapped in later without
touching call sites.

**Fallback chain is mandatory.** `Typography` must resolve each face through a
lookup that falls back to the current system definition when registration
fails. A missing font file degrades to today's appearance; it never crashes or
renders blank.

### 4. Texture

- **Graph grid.** 8pt dotted rule in `earth3` at 0.35 alpha. Generated once as
  a single screen-sized texture in `DigScene.didChangeSize`, drawn at
  `zPosition -2`. Shows through behind the slab.
- **Paper fibre.** 256x256 tile generated at launch via `CIFilter.randomGenerator`,
  blurred slightly, tinted, cached. Drawn at ~3% alpha, `zPosition -1`.
  Generated rather than shipped so it tints with the ramp and keeps the bundle flat.
- **`Measure.cardRadius` goes 4 to 0.** Notebooks have no rounded corners.
  Cards become ruled boxes — a hairline outline over the page — not filled panels.
- `SpecimenRule` keeps its dashed form but restyles to `earth3`.

### 5. Colour semantics: red at rest versus red in motion

The accent is stamp red `#B03A2B`. `Ink.danger` is also red, and the existing
discipline is that red always means "you are breaking it". Two reds would break
that, so the two meanings separate by **motion** rather than hue:

- **Damage** — a transient `stamp` ink-bleed blooms at the fracture point over
  ~200ms, then settles into a permanent diagonal hatch (`earth8` at 0.5, 2px
  spacing) over the fractured cells. Fast enough to read preattentively, and it
  leaves a record on the page.
- **Actions** — flat, static `stamp`. Primary buttons and the wordmark never
  animate in this colour, so they never compete with a bleed.

One hue, two behaviours. `Ink.danger` and `Ink.accent` collapse into the single
token `Ink.stamp`.

### 6. Night digs drive the whole page

`SlabRenderer.lightLevel` currently dims only the slab. Against a cream page
that reads as a rendering bug, and a bright phone at night is a real complaint.
One `lightLevel` now drives both surfaces:

- `lightLevel` keeps its existing 0...1 range; the simulation is unchanged.
- Page lerps `earth1` toward `#2A2620`, reaching full darkness at `lightLevel`
  0.35 and clamping below that. The page never reaches black.
- Grid alpha rises as the page darkens so it does not vanish.
- Text lerps `earth8` toward `earth1` — the ramp inverts.

This also yields a genuine dark mode as a side effect.

**Structural consequence.** `Ink` can no longer be static constants. It becomes
a struct with instance properties, with `Ink.day` and `Ink.night` presets and a
`lerp(_:)`. A small `Theme` observable derives the current `Ink` from
`lightLevel` and is injected through the SwiftUI environment.

Scope control: only `DigView` and `DigScene` consume the dynamic theme in this
pass. `RootView`, `SpeedMeter`, and `DebugOverlay` read `Ink.day` directly.
Wiring them to the environment is a later, mechanical change.

## Files

| File | Change |
|---|---|
| `BonedustCore/Sources/BonedustCore/UI/EarthRamp.swift` | **New.** Ramp and accent values as plain `(r,g,b)` tuples. No SwiftUI. |
| `Bonedust/UI/DesignTokens.swift` | Rewrite. `Ink` becomes a struct over the ramp; `Typography` gains the fallback chain; `Measure.cardRadius` to 0. |
| `Bonedust/UI/Theme.swift` | **New.** Observable deriving `Ink` from `lightLevel`; environment key. |
| `Bonedust/Dig/SlabRenderer.swift` | Retune `SlabPalette` against the ramp; bone to `#FDFAF2`; slab border; fracture hatching. |
| `Bonedust/Dig/DigScene.swift` | Grid texture, paper-fibre tile, page background, `lightLevel` coupling, zPosition order. |
| `Bonedust/Dig/DigView.swift` | Consume `Theme` from the environment; restyle. |
| `Bonedust/UI/SpeedMeter.swift` | Restyle to `Ink.day`. |
| `Bonedust/UI/DebugOverlay.swift` | Restyle to `Ink.day`. |
| `Bonedust/App/RootView.swift` | Restyle to `Ink.day`; install `Theme` in the environment. |
| `Bonedust/Resources/Fonts/` | Add `BebasNeue-Regular.ttf`, `CourierPrime-Regular.ttf`, `CourierPrime-Bold.ttf`; update README and the `UIAppFonts` entry in `project.yml`. |
| `Resources/Assets.xcassets/LaunchBackground.colorset` | `earth1`. |
| `Resources/Assets.xcassets/AppIcon.appiconset` | Regenerate against the new ground. |

## Testing

Colour and type are verified by eye, with three exceptions that are cheap to
automate and go in the existing `BonedustCore` suite:

1. **Ramp monotonicity.** Relative luminance strictly decreases from `earth0`
   to `earth8`. Catches a mistyped hex during any future retune.
2. **Contrast.** Every text-on-surface pair the design uses meets WCAG AA
   (4.5:1 for body, 3:1 for large display), in both the day and night presets.
   This constraint is why no text sits above `earth5`: against a page at
   `earth1`, `earth4` reaches only 2.7:1, and `earth5` is the first stop that
   clears 4.5:1. The test exists to stop a future retune from quietly
   reintroducing light-on-light secondary text.
3. **Bone/page separation.** Bone and page differ by at least 5% relative
   luminance, which is the regression that would reintroduce the edge-bleed.

Everything else is visual verification on device, in daylight and in a dark
room, at the `lightLevel` extremes and at 0.35.

The 94 existing `BonedustCore` tests cover simulation and economy and are
unaffected; they must stay green.

## Risks

- **Font acquisition blocks the type work.** Both faces are SIL OFL and freely
  downloadable, but nothing in §3 lands until the `.ttf` files are in the repo.
  Every other section proceeds independently.
- **`SlabPalette` retune is the slow part.** No test tells you the dirt looks
  right. Budget roughly two hours of looking at it on a device.
- **`Ink` becoming non-static touches every call site.** Mechanical, but it is
  the change most likely to produce a long diff.

## Effort

About one day. Roughly: ramp and tokens 1h, `SlabPalette` retune and visual
verification 2h, scene texture and night coupling 1.5h, font integration 0.5h
once files exist, view restyling 2h, tests 0.5h.
