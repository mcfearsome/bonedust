# Game Center

Three leaderboards and ten achievements, all of them a mirror and none of them a record.

## The entitlement

`ios/Bonedust/Bonedust.entitlements` carries two keys, and they are read by different Apple
systems that both key off the same app identifier:

```xml
<key>com.apple.developer.devicecheck.appattest-environment</key>  <!-- App Attest -->
<key>com.apple.developer.game-center</key>                       <!-- this -->
```

Game Center needs nothing beyond `<true/>`. It is enabled per app record in App Store
Connect; the entitlement only says the binary is allowed to ask.

## Why every call fails soft

`GameCenterService` never checks a result, never retries, and nothing in the dig loop waits
on it. That is deliberate, and it is also why a missing entitlement did not show up as a
crash or a test failure for six milestones: a player who is not signed in, who is offline,
or who is somewhere Game Center does not operate has to get exactly the same game as
everyone else.

The authoritative numbers live in the SwiftData save file and in the crew ledger. Game
Center is a second place to look at them, so "it did not submit" is not a state the app has
to represent anywhere.

One consequence worth naming: the sign-in sheet's view controller argument in
`authenticateHandler` is deliberately dropped. Somebody who opened the app to brush dirt off
a rock does not get interrupted by a modal about scores.

## Gentle mode

Gated at this boundary rather than at the call sites, in `record(_:rewards:gentleMode:)`.
§7 excludes Gentle runs from leaderboards, which are competitive — not from achievements,
which are not. One gate is harder to forget than six.

## What has to exist in App Store Connect

The identifiers are compiled in, so these have to match exactly or a submission silently
goes nowhere. Leaderboard ids come from `Leaderboard.all`; achievement ids come from
`content.json`, which means a mismatch there can be corrected in data rather than in a build.

### Leaderboards

| identifier | submits | format |
|---|---|---|
| `bonedust.leaderboard.streak` | `meta.longestStreak` | Integer, high to low |
| `bonedust.leaderboard.best_slab` | `meta.bestSlabPayout` | Currency (USD), high to low |
| `bonedust.leaderboard.contribution` | `meta.lifetimeContribution` | Currency (USD), high to low |

All three are lifetime bests, so they want **Best Score** rather than Most Recent, and no
score reset.

`bonedust.leaderboard.contribution` ranks the same number the server ranks for the crew
board in `CREW_LEDGER.md`. Two boards over one quantity is intentional: Game Center ranks a
player among their friends, the server ranks them among everyone, and only the server can be
trusted, because only it sees the attested payments.

### Achievements

Ten, each all-or-nothing — `report(achievementIDs:)` sets `percentComplete = 100` and never
reports partial progress.

| identifier | name |
|---|---|
| `first_set` | Articulated |
| `flawless` | Not a mark on it |
| `big_slab` | Museum piece |
| `streak_3` | Keeping him sweet |
| `streak_10` | Almost respectable |
| `species_10` | A drawer of your own |
| `species_all` | The whole cabinet |
| `charmouth_cleared` | Done with Dorset |
| `tier_5` | Five weeks of this |
| `contribution_10k` | Ten thousand of his money |

Achievements are recomputed from the whole of `MetaProgress` after every run rather than
fired as events, so one added in a later version is awarded retroactively for play that
already happened, and none can be lost to the app being killed at the wrong moment.
Re-reporting an already-earned achievement is a no-op on Apple's side, which is what makes
that safe.

## Team ID

Game Center, like App Attest, is scoped to `teamID.bundleID` — here
`VHH2P6SR8R.dev.codenerd.bonedust`, the individual membership. The team and the bundle id
are independent: Bonedust is published by Code Nerd LLC and signed by the personal team, and
nothing in either system requires them to agree.

`make team-id` prints what the installed certificates actually claim, reading each
certificate's `OU` rather than the parenthetical in its common name — those are different
values on this machine (`VHH2P6SR8R` against `KVYH9JS6NS`), and the parenthetical is the
*user* id.
