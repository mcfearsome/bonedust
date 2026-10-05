# BonedustUITests

Real touches against the real app, on a simulator. It launches Bonedust, starts a dig and drags a
finger across the slab the way a player does. What it reads back is only what a player or VoiceOver
could: accessibility values, and the pixels of a screenshot of the real framebuffer.

## Why it exists

Every other test in this project builds the thing it tests. The offscreen scene tests make their own
`DigScene` and their own `SKView`, so they can see only what the scene does in the circumstances the
test arranged. Until the scale-mode fix they built `DigScene(size:)`, a scene of exactly the size each
test wanted, and **so none of them could observe anything about how the app actually constructs
one**. The app builds `DigScene()` with no size and relies on SpriteKit to size it, and SpriteKit was
not. The scene stayed 1x1 and was stretched to fill the view, the slab (inset 12 scene units by the
mount) came out 0x0, `gridPoint` refused every touch, and the game's central picture was blank and
untouchable, while more than a hundred tests passed.

The scene tests build `DigScene()` now, but still inside a detached `SKView`: no window, no SwiftUI
layout, no safe areas, no compositor, and no `UITouch`, which a test cannot construct. This is the
only thing here that exercises all of that together. Driven by hand it found, on the branch that
restyled the app: the 1x1 scene and the 0x0 slab, the dropped touches, M1's dust (a flicker, from
266pt motes at 17,000pt/s, visible only in video of a real dig), and the system Reduce Motion setting
reaching the alarm pulse, which a unit test cannot set. The first time the check below ran it found
one more, which had been there since M1: the slab was drawn upside-down against the touches, so a
drag 30% of the way down it cleared a strip 70% of the way down. No other test could tell, because a
sweep of evenly spaced rows is symmetric about the middle and looks right either way. It is not a
replacement for the fast tests. It is the check that they are testing the thing the app really is.

## Running it

A simulator is needed, and both take real time because a dig runs on the real clock.

    make test-ui       # the check, about twenty seconds
    make ui-capture    # the camera, about a minute and a half

Neither is part of `make test`, and `make app` and `make test-app` do not build them: the target has
its own scheme, `BonedustUI`. `SIM` picks the simulator as it does for `make test-app`.

**The check**, `testARealDragDigsTheSlabUnderTheFinger`. It drags across the slab and asserts that the
slab has a real size, that the daylight clock started (it starts on the first touch, so this is the
touch reaching the engine), and that the pixels that changed are where the finger went, not mirrored
from it. The slab is random each time, so it asserts where something changed and never what is under
it.

**The camera**, `testCaptureTour`. Not a check. It digs a whole slab with sweeps at a careful speed
and then a fast one, and writes screenshots and a `markers.txt` log; `scripts/ui-capture.sh` runs it
inside a screen recording and puts `dig.mp4` beside them. Choose what to dig in the environment:
`BONEDUST_UI_SITE` (a word from the site's name), `BONEDUST_UI_TOOL` (a tool button's name, e.g.
`Air blower`; the plain Brush only gets through the clay in the sixty seconds of daylight),
`BONEDUST_UI_CAREFUL` and `BONEDUST_UI_FAST` (drag speeds, points a second), `BONEDUST_UI_ROWSTEP`.

    BONEDUST_UI_TOOL="Air blower" BONEDUST_UI_SITE="Night" make ui-capture

To look at the video, `ffmpeg -i dig.mp4 -vf fps=60 frames/%05d.png` gives frames. Comparing
consecutive frames over the slab is how M1's dust flicker was measured. The timestamps in
`markers.txt` are wall-clock, so they line up with the recording to within a second or so.

## What it relies on

The app's accessibility labels are the contract, because this is black-box: `Dig slab` (the slab),
`Daylight remaining` (its value reads "60 seconds of 60"), the title screen's `New run` button, the
site cards (their label contains the site's name) and the tool buttons (named after the tool).
Renaming one breaks the driver, on purpose: they are also what VoiceOver reads.

It also turns off Settings, `Listen while digging`, and the app saves that, so a simulator used
for this stays that way. With the microphone on, a dig starts an audio engine on the main thread,
and on a simulator that can leave the app unresponsive for minutes while XCTest waits for it to
go idle.

It is not run anywhere automatically. There is no CI configuration in the repository today. If CI
is added, this wants its own job on a macOS runner with a booted simulator, kept apart from the unit
tests because it is real-time and depends on the device.
