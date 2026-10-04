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
| `earth2` | `#DFD4BB` | Non-text fills only: progress troughs, inactive track |
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

The night page needs its own accents. The day values sit at 2.2–2.5:1 against
`nightPage`, far under AA, and an earlier draft had `Ink.night` reuse them — the
contrast rule had only ever been checked against the cream page.

| Token | Hex | On `nightPage` |
|---|---|---|
| `stampNight` | `#E0705C` | 4.76:1 |
| `gemNight` | `#56B8C8` | 6.51:1 |
| `safeNight` | `#7FBF6A` | 6.85:1 |

`gemNight` and `safeNight` are the *original* values from the dark UI this
redesign replaces. That palette was never wrong; it was a dark-mode palette, and
it is correct again at night.

**On the day page, nothing above `earth5` carries text, and `earth2` carries none at all.**
(At night the ramp inverts and `earth1` is the text colour.)
`earth5`-on-`earth2` is 4.25:1 and `stamp`-on-`earth2` is 4.09:1, both under AA.
§4 already makes cards ruled boxes rather than filled panels, so `earth2` is a
fill for troughs and inactive tracks. Text sits on `earth1` or `earth0`.

**The specimen mount.** A cleared slab is *light*, not dark — `matrix` is the
top layer and every site paints it pale. Against a cream page this is fatal:
green_river's `matrix #E8DBBA` sits at 1.09:1 against `earth1`, so a
fully-excavated slab would vanish into the paper. Four of five sites have the
same problem to a lesser degree.

The fix is a **mount**: an `earth6 #4A3D2E` panel behind the slab, extending 6pt
past it on every side. A specimen pinned to dark card is the correct notebook
object, and it separates the slab from the page at 8.3:1 while clearing the
palest site matrix at 5.8:1 — regardless of which site is loaded.

The mount also removes three changes an earlier draft of this spec called for.
Bone stays at its current `RGB8(242, 233, 214)`, and the slab needs no drawn
border, because the mount margin *is* the border.

**And the palette does not need retuning at all.** Measured against the mount,
every existing site matrix already clears 3:1 by a wide margin — the palest,
green_river at `#E8DBBA`, reaches 7.6:1, and the darkest, wheeler at `#C4C0AE`,
reaches 5.8:1. The site palettes are already warm earth tones in the ramp's
family; what was broken was the *page*, not the dirt. So the palette work
collapses from "retune four palettes by eye" to "add a test that pins the
margin." If that test ever fails, the palette changes then — not now.

### 3. Type

Three faces, each with one job. Two are new.

| Role | Now | Proposed | Licence |
|---|---|---|---|
| Display, wordmark, labels | SF Pro Black Expanded | Rubik Dirt | SIL OFL |
| Numerals | SF Mono | Courier Prime | SIL OFL |
| Body and controls | SF Pro | SF Pro (unchanged) | system |

Body stays on SF Pro deliberately: it gets Dynamic Type right for free, and a
notebook's body text being neutral is correct. The character lives in the
display face and the numerals.

**Rubik Dirt is not a new decision.** `Resources/Fonts/README.md` already names
it, documents the OFL rationale for bundling it in a paid app, and gives the
exact four-step drop-in. This spec adopts that decision rather than relitigating
it; a rough, dirt-textured display face is also a better fit for stamped
notebook headings than a clean condensed one. Courier Prime for numerals is the
only genuinely new type choice here. Both faces are SIL OFL and can be committed
to the repo.

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
  leaves a record on the page. Under **Reduce Motion** the bloom does not scale:
  it fades in place. A sudden expanding shape at the point of attention is
  exactly what that setting exists to suppress, and the hatch carries the
  information regardless.
- **Actions** — flat, static `stamp`. Primary buttons and the wordmark never
  animate in this colour, so they never compete with a bleed.

One hue, two behaviours. `Ink.danger` and `Ink.accent` collapse into the single
token `Ink.stamp`.

### 6. Night digs drive the whole page

`SlabRenderer.lightLevel` currently dims only the slab. Against a cream page
that reads as a rendering bug, and a bright phone at night is a real complaint.
One `lightLevel` now drives both surfaces:

- `lightLevel` keeps its existing 0...1 range; the simulation is unchanged.
- The palette **switches**, it does not blend. Below a threshold the page is
  `nightPage` and the ramp is inverted; above it, the day palette. No
  intermediate palette ever reaches a screen.
- Grid alpha stays the same in both palettes. An earlier draft raised it at
  night to stop the grid vanishing; measured, the grid is *more* visible at
  night, not less — dot-against-page contrast is 1.17:1 by day and 1.32:1 at
  night, because `hairline` moves further from the page than the page moves
  from it. The boost would have been solving a problem that does not exist.

**Why a switch and not a crossfade.** Blending two inverted palettes drives
text and page toward each other, and in the middle they meet. Measured on this
ramp, ink-on-page collapses from 13.7:1 at full day to **1.09:1 at the midpoint**,
and stays under AA from roughly t=0.23 to t=0.80:

| blend | ink | page | contrast |
|---|---|---|---|
| 0.00 | `#1C1A17` | `#EDE4CF` | 13.72:1 |
| 0.35 | `#656157` | `#A9A292` | 2.43:1 |
| 0.50 | `#847F73` | `#8C8578` | **1.09:1** |
| 0.69 | `#ACA596` | `#666156` | 2.52:1 |
| 1.00 | `#EDE4CF` | `#2A2620` | 11.89:1 |

`night_dig` is the only dim site and it runs at `lightLevel` 0.55, which lands
at t=0.69 — **2.52:1, unreadable**. A continuous blend would have shipped the
game's one night level with illegible text. `lightLevel` is also static per site,
set once when the scene is configured, so there is no transition to smooth and
nothing is lost by switching outright.

This also yields a genuine dark mode as a side effect.

**Structural consequence.** `Ink` can no longer be static constants. It becomes
a struct with instance properties and `Ink.day` / `Ink.night` presets. A small
`Theme` observable selects between them from `lightLevel` and is injected through
the SwiftUI environment. `Ink.lerp` exists for a future animated crossfade and is
tested, but nothing drives the live palette through it — see the table above.

Scope control: only `DigView` and `DigScene` consume the dynamic theme in this
pass. `RootView`, `SpeedMeter`, and `DebugOverlay` read `Ink.day` directly.
Wiring them to the environment is a later, mechanical change.

### 7. Cel shading

The slab is already four discrete palette colours per layer. What stops it
reading as cel-shaded is that `SlabRenderer.colour()` then smears those bands
with four continuous operations: `wearColorBlend` 0.55, `cellNoise` 0.07, the
`x1.12` / `x0.86` bone relief, and `lightLevel`. Flattening those into steps and
adding a real edge is the whole change. No shader.

**Quantize the lighting, never the albedo.** Posterizing each channel
independently shifts hue. Measured on the standard palette at 8 levels:

```
topsoil  RGB8(74, 52, 40)  ->  (73, 36, 36)     visibly redder
```

and because `cellNoise` moves each cell +/-7%, neighbouring cells land in
different buckets and the slab reads as brown-green static rather than flat
colour. So every palette value stays exact and only the shade multiplier steps.
This was caught by rendering it, not by reasoning about it.

The pass, in order:

1. **Wear quantizes to 4 steps** before the lerp. Scraping still shows progress
   -- the renderer's comment warns that without it "brushing feels unresponsive
   even though it is working" -- but in bands rather than a gradient.
2. **Cell noise quantizes to 3 shade steps** (-7%, 0, +7%) instead of a
   continuous jitter.
3. **A semantic ink edge** on bone and gem at depth 0, right and bottom only,
   `Earth.s8` at 0.72. Two-sided rather than four keeps a thin specimen's
   interior, and the edge is skipped where the run is under 3 cells so
   green_river's paper-thin fish survive. Outlines are drawn from `flags`, not
   from colour difference, which is why this belongs on the CPU: a fragment
   shader cannot tell gem-on-matrix from a noise boundary.
4. **The soft bone relief is removed.** The ink edge replaces it.

**The dirty rect had to grow.** An earlier draft of this spec claimed the
neighbour reads needed no new plumbing, because `redraw()` already inflated by
one cell for the bone relief. That was wrong: the run-length guard reads *two*
cells back, so clearing a cell left the cell two positions behind it stale —
reproduced at (22,50) and (60,22). `redraw()` now inflates one back and two
forward.

### 7a. The tell becomes a stipple

A naive posterize would have deleted the game's only pre-exposure read on the
fossil. `boneTellTint` is 0.20, and at 6 levels the tinted and untinted
sandstone quantize to the identical byte triple -- the tell goes pixel-for-pixel
invisible. Quantizing only the shade avoids that, but the tell is worth
improving on its own terms.

**The tell becomes a pattern instead of a tint**: on depth-1 sandstone over
bone, cells where `x % 2 == 0 && y % 2 == 0` go 60% toward bone. A pattern
survives any future posterize, and hatching is the correct natural-history-plate
idiom. Rendered at 9x with the cel pass applied, the stipple reads the buried shell's
outline clearly. How much better it is than the tint is **not settled**: a
separate 5x render of the shipped renderer found the 20% tint perfectly
visible, so the earlier claim that it is "nearly invisible" overstated the
case. What is certain is that the stipple survives a posterize and the tint
does not, and that the stipple is the louder of the two. Which is *right* is a
device call, not a measurement — see the A/B step below.

**This is a game-feel change, not only a visual one.** `SlabRenderer`'s own
comment says learning to see the tell "is the difference between a careful
player and a fast one". The stipple is not simply better -- it is louder, and a
louder tell spends that skill. So **both constants ship**: `boneTellTint` stays
and `boneTellStipple` is added beside it. `DebugOverlay`'s knob list is hand-written, not derived from `SimTuning`, so a
new constant needs a row adding before it is reachable — `boneTellStipple` has
one. With both rows present the A/B is a drag rather than a rebuild, and either
constant set to zero gives the pure case. The default ships as stipple 0.60 /
tint 0; if it plays worse, the fallback is a slider move, not a code change.

## Files

| File | Change |
|---|---|
| `BonedustCore/Sources/BonedustCore/UI/EarthRamp.swift` | **New.** Ramp and accent values as plain `(r,g,b)` tuples. No SwiftUI. |
| `Bonedust/UI/DesignTokens.swift` | Rewrite. `Ink` becomes a struct over the ramp; `Typography` gains the fallback chain; `Measure.cardRadius` to 0. |
| `Bonedust/UI/Theme.swift` | **New.** Observable deriving `Ink` from `lightLevel`; environment key. |
| `BonedustCore/Sources/BonedustCore/Content/ContentModels.swift` | **No change expected.** `SlabPalette` lives here, not in the renderer; see the note below on why it does not need retuning. |
| `BonedustCore/Sources/BonedustCore/Resources/content.json` | **No change expected**, for the same reason. Three sites override the palette here (`wheeler`, `green_river`, `hell_creek`); `charmouth` and `night_dig` inherit. |
| `Bonedust/Dig/SlabRenderer.swift` | Fracture hatching, plus the cel pass of §7: stepped wear, quantized shade, semantic ink edge, stipple tell. |
| `BonedustCore/Sources/BonedustCore/Sim/SimTuning.swift` | Add `boneTellStipple: Float = 0.60` beside the existing `boneTellTint`, so the debug overlay gets a slider for each. |
| `Bonedust/Dig/DigScene.swift` | Mount panel, grid texture, paper-fibre tile, page background, `lightLevel` coupling, zPosition order. Also removes the hardcoded `0x221813` at line 41, which duplicates `Ink.ground`. |
| `Bonedust/Dig/DigView.swift` | Consume `Theme` from the environment; restyle. |
| `Bonedust/UI/SpeedMeter.swift` | Restyle to `Ink.day`. |
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
   The night pairs are tested against `nightPage` with the night accents, not the
   day ones. The suite also pins the luminance function itself against WCAG
   reference values (`#595959` on white = 7.00, pure-red Y = 0.2126, pure-blue
   Y = 0.0722): without those, a simplified `channel()` or a one-digit threshold
   typo passes every ratio assertion while inflating contrast throughout.
   This constraint is why no text sits above `earth5`: against a page at
   `earth1`, `earth4` reaches only 2.7:1, and `earth5` is the first stop that
   clears 4.5:1. The test exists to stop a future retune from quietly
   reintroducing light-on-light secondary text.
3. **Mount separation.** For every site in `content.json`, including those that
   inherit the defaults, `matrix` clears 3:1 against the mount. This is the
   regression that would reintroduce the edge-bleed, and it must run per site
   because three sites override the palette independently.

Everything else is visual verification on device, in daylight and in a dark
room, at the `lightLevel` extremes and at 0.35.

The 94 existing `BonedustCore` tests cover simulation and economy. The palette
retune touches `SlabPalette`, which `ContentTests` round-trips through `Codable`,
so that suite is in scope and must stay green.

Tests split by target: ramp, contrast, and per-site mount separation go in
`BonedustCore/Tests/BonedustCoreTests/` (no simulator needed); anything touching
`Ink` or `Typography` goes in `ios/BonedustTests/AppLayerTests.swift` alongside
the existing `DigEngineTests`. Both suites are XCTest.

## Risks

- **Font acquisition blocks the type work.** Both faces are SIL OFL and freely
  downloadable, but nothing in §3 lands until the `.ttf` files are in the repo.
  Every other section proceeds independently.
- **The restyle surface is 51 call sites.** `DigView` has 22 `Ink` references,
  `RootView` 20, `SpeedMeter` 9. Mechanical, but it is the longest diff.
- **`DebugOverlay.swift` is out of scope.** It references no design token, so
  the restyle does not reach it.
- **`Ink` becoming non-static touches every call site.** Mechanical, but it is
  the change most likely to produce a long diff.

## Effort

Roughly 1.5 days. Ramp and tokens 1h, guard tests 0.5h, font integration 0.5h
once the files exist, mount plus scene texture plus night coupling 2h, fracture
hatching 1h, the cel pass and the stipple tell 3h, view restyling 2h, assets
0.5h.

Dropping the palette retune took roughly two hours of by-eye work out of this
estimate, and took the only genuinely unverifiable task out of the plan.
