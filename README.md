# Bonedust

A premium iOS game about brushing sediment off fossils for a man you owe money to.

Brush faster and you clear more rock; brush exposed bone too fast and it cracks,
which ruins its value. Five slabs to a run, sixty seconds of daylight each, and an
installment due to the Collector at the end of it. Every dollar anyone earns also
pays down one shared crew debt of **$2,400,000,000**.

## Layout

```
ios/BonedustCore/     Swift package: simulation, generation, economy, content.
                      Pure Swift — no SpriteKit, SwiftUI or UIKit, enforced by the
                      package declaring macOS support.
ios/Bonedust/         The app: SpriteKit rendering, touch input, haptics, audio,
                      SwiftUI screens.
ios/BonedustTests/    App-layer tests. The simulation suites live in the package.
ios/project.yml       XcodeGen input. The .xcodeproj is generated, never edited.
shared/constants.json Generated from Swift. The Rails service loads this so both
                      sides score a slab with the same numbers.
shared/ledger.json    Crew debt total, milestone ladder, leaderboard definitions.
server/               Rails 8 API for the crew ledger. Deploys to api.bonedust.app.
shared/golden/        Cross-language fixture: Swift emits it, Ruby must reproduce it.
docs/CREW_LEDGER.md   Debt, milestone rewards, leaderboards, anti-cheat.
DECISIONS.md          Every judgement call, with the reason.
```

## Build and test

```sh
make test-core     # simulation + economy suites. No simulator, ~25s.
make bench         # worst-case frame for the brush loop.
make project       # regenerate ios/Bonedust.xcodeproj from project.yml.
make app           # build the app for a simulator.
make test-app      # app-layer tests.
make constants     # regenerate shared/constants.json after a tuning change.
make simulate      # win rate per installment tier, 10,000 scripted runs.
./scripts/verify-ios.sh   # compile every iOS source without needing a simulator.

make server-setup  # bundle, create the database, seed the milestone ladder.
make server-test   # 67 examples: plausibility, idempotency, attestation, boards.
make server-golden # the cross-language check alone. No bundler, no database.
make server-load   # 500 concurrent payments; needs a running server.
make golden        # regenerate the fixture after a content or tuning change.
make render        # slab PNGs, headlessly. Screenshots, and a way to see the game.
```

`make test` runs the core suite *and* the cross-language golden check, because a tuning
change that passes the Swift tests while breaking the Ruby port would make the server start
rejecting honest payments.

`make test-core` is the loop that matters day to day. The simulation is a Swift
package specifically so that the tests covering removal, cracking, metrics, payout
and determinism run on the host in seconds instead of booting a simulator.

### A simulator runtime is needed for `make app`

`make test-core`, `make bench` and `./scripts/verify-ios.sh` work on any machine with
Xcode. `make app` and `make test-app` need a simulator runtime that the installed
Xcode supports — see **Toolchain** in `DECISIONS.md` if `xcodebuild` reports
"Unable to find a destination".

## Where things stand

- **M1 — slab simulation and feel: complete.** Seeded generation, brushing, cracking,
  metrics, payout, SpriteKit rendering, coalesced touch input, speed meter, haptics,
  synthesized audio, dust, and a debug overlay with a slider per tuning constant.
- **M2 — run loop: complete.** Five days, the installment, slab results, run end,
  Reputation, and a one-slot autosave that restores a part-dug slab with daylight
  paused. Plus the §9 economy simulator (`make simulate`).
- **M3 — content and charms: complete.** Seven tools (three brushes, four passives),
  seventeen charms, the supply tent with restock and resale, kit that carries across
  successful runs, and a per-day site override. Tools and charms both resolve into one
  `ModifierSet`, so nothing special-cases a charm inside the brush loop.
- **M4 — meta progression: complete.** The Collection as a museum drawer with best
  exposure and intact per species, two skeleton sets with permanent perks, ten
  achievements evaluated from pure rules, three Game Center leaderboards, and
  Reputation-gated brush trails.
- **M5 — crew ledger: complete.** Rails 8 API for `api.bonedust.app`, App Attest, a
  server-side plausibility ceiling with a cross-language golden test, the durable payment
  queue, cached milestone unlocks and the Crew Ledger screen. 67 server examples; 500
  concurrent payments lose nothing.
- **M6 — polish: in progress.** Crack and gem particles, a VoiceOver announcement on every
  crack, Dynamic Type-safe control heights, and `make render` — which writes slab PNGs
  headlessly and is both the App Store screenshot pipeline and the only way to look at the
  game without a device.

179 core tests pass. App-layer tests compile but cannot be *run* here — see
**Toolchain** in `DECISIONS.md`.

## The one rule

Simulation logic stays pure and stays in `BonedustCore`. If something in there needs
to import SpriteKit, it belongs in the app instead. Determinism is load-bearing: the
server regenerates each slab from its seed to check that a reported payout was
possible, so `random()` anywhere in the simulation is a bug that shows up as players
being wrongly accused of cheating.
