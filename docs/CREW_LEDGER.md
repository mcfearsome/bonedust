# The Crew Ledger

One global debt the whole player base pays down together. This document is the
design; `shared/ledger.json` is the data; `/server` is the implementation.

## The number

**$2,400,000,000.** The brief's $2.4M, scaled by a thousand. Keeping the digits
makes it recognisable; the extra three zeroes make it clearly generational rather
than something a dedicated crew clears in a fortnight.

### Is it reachable?

It has to be, or the ending is a lie. The arithmetic:

| | |
|---|---|
| Median slab, early game | ~$80 |
| Median run (5 slabs) | ~$400 |
| Late run — Hell Creek or night dig, good charms | $2,500–$3,500 |
| Casual player lifetime (≈15 runs) | ~$6,000 |
| Committed player lifetime (100+ runs, late tiers) | $150,000–$400,000 |

A premium iOS game that does well sells somewhere around 200k copies. At a blended
average of **$12,000 lifetime per player** that is $2.4B. So the number is a bet on
the game succeeding — which is the bet anyway — and the ladder is front-loaded so
that nobody's progress depends on that bet paying off.

### The lever, if the bet is wrong

The ladder lives in `shared/ledger.json` and is seeded into the `milestones` table.
Re-tuning it is a migration plus a content update, **not an App Store review**. The
client renders whatever the server sends and only needs to recognise the `unlocks`
identifiers, all of which ship in v1. If the population comes in at a tenth of plan,
the amounts move; the design does not.

## Milestone ladder

Twelve rungs, geometric. Every rung gives every player something, and **every reward
is permanent and retroactive** — install the game the day after Paid In Full and you
still get all twelve. Punishing late arrivals would make the communal framing a lie.

| # | Amount | Name | What the crew gets |
|---|---|---|---|
| 1 | $1M | First Ledger Page | **Hell Creek** site · crew badge stamp |
| 2 | $5M | The Vault Cracks | **Collector's vault** rare charm pool |
| 3 | $20M | Lights Out | **Night digs** site |
| 4 | $50M | Union Rates | Dental pick + Sieve enter the shop pool for good |
| 5 | $100M | Field Notes | Collector's annotations in the Collection · oak drawer skin |
| 6 | $250M | Bone Dust Trail | Three cosmetic brush trails |
| 7 | $500M | The Deep Quarry | **Solnhofen** site (Jurassic lagoon) |
| 8 | $800M | Salvage Rights | Every run starts with a $50 crew stake |
| 9 | $1.2B | The Collector Blinks | Installment growth drops 1.32 → 1.28, crew-wide |
| 10 | $1.6B | Provenance | Crew seal on specimen labels, +5% payout |
| 11 | $2B | Last Invoice | **The Collector's Quarry** — his own site, opened to you |
| 12 | $2.4B | Paid In Full | Ending beat · New Game Plus at $6B · prestige frame · Founder stamp |

Three things that ladder is doing deliberately:

- **Content first.** The three sites the brief gates on the ledger (Hell Creek,
  night digs) sit at rungs 1 and 3, in reach within weeks of launch. A player should
  never be locked out of core content waiting on a number in the hundreds of millions.
- **Rungs 8, 9 and 10 make the game easier.** A starting stake, a gentler
  installment curve, a payout bonus. This is a feedback loop on purpose: the crew's
  work makes the Collector weaker for everybody, which is the entire emotional
  premise. It is bounded to three small effects so it cannot run away.
- **The reward for the top is a bigger debt.** Paid In Full opens New Game Plus
  with $6B and "The Collector's heir". The joke is the point.

### Reward kinds

`unlocks` entries use a `kind:id` form so the client can switch on them:

- `site:` — a new dig site, appended to site select
- `charmpool:` — opens a pool of charms in the supply tent
- `tool:` — adds a tool to the shop pool
- `perk:` — a crew-wide `ModifierSet` contribution, or a named economy change
- `collection:` / `label:` / `drawer:` / `trail:` / `stamp:` / `frame:` — cosmetic
- `ending:` / `mode:` — story beat and New Game Plus

A client that meets an identifier it does not know ignores it and still shows the
milestone as reached. That is what lets the ladder be re-tuned and extended server
side without stranding old builds.

## Leaderboards

Five boards. The hard rule:

> **A leaderboard score is never submitted by the client. Every board is derived
> from the validated `payments` table.**

The ledger already checks every payment against App Attest and against
`maxPayout(seed, charms)` recomputed server-side from the server-issued seed (§6). If
the leaderboard reads from that same table, it inherits all of it for free. A board
fed by a client-reported score would be a second, unprotected way in — and the first
thing anybody would attack.

| Board | Sort key | Window |
|---|---|---|
| Paid to the debt | `diggers.paid_total` | all time |
| This season | `diggers.paid_season` | season |
| Best single slab | `diggers.best_slab_amount` | all time |
| Longest run streak | `diggers.best_streak` | all time |
| Flawless slabs | `diggers.flawless_slabs` | all time |

### Shape

`GET /v1/leaderboard?board=contribution&window=all_time` returns the top 100 **plus
the caller's own rank and the five diggers either side of it**. At rank 40,000 a bare
top-100 list tells you nothing; your own neighbourhood is the part you actually come
back for.

### Identity, without accounts

There are no accounts (§2) — just an install UUID in the Keychain. So:

- Default display is **"A digger"** plus the rank. You are on the board from the
  first payment, anonymously.
- Opting in copies the **Game Center alias** into `diggers.display_name`. That is the
  only name the server ever stores, and it is the player's choice to send it.
- Opting back out clears the column. Rank is unaffected either way.

### Performance

Leaderboard reads must not scan `payments`. A `diggers` rollup row per install is
updated in the **same transaction** as the payment insert — `paid_total`,
`paid_season`, `best_slab_amount`, `best_streak`, `flawless_slabs` — with a B-tree
index per sort key. Reads are then an index scan of the top 100. Cached 30 s behind
an ETag, like `/v1/ledger`.

### Gentle mode

Gentle mode (§7) halves crack chance and multiplies payouts by 0.8. Those players are
excluded from every board, as the brief requires — and their payments **still count
toward the crew debt in full.** Accessibility must not cost you the communal part of
the game, only the competitive part.

## Season

`paid_season` and the "diggers this season" count need a season. A season is a
calendar quarter, stored as a row so it can be changed without a deploy. Seasons
reset the season board only; `paid_total` and the debt never reset.

## Where it runs

**`api.bonedust.app`.** The apex is left for a marketing page, and a subdomain means the
API can change hosts with one DNS record without touching whatever serves the website. The
client reads the base URL from `Info.plist` (`BonedustLedgerBaseURL`), so pointing a debug
build at a local server is an edit to `ios/project.yml` rather than to code.

Rails 8 rejects requests for hosts it does not recognise, so production names
`api.bonedust.app` explicitly along with the platform hostnames Fly and Render add. `/up` is
excluded from that check, because health probes arrive on an internal address — which is a
confusing way to discover host authorization the first time a deploy answers 403 to
everything.

## What the server actually verifies

From the seed alone it reproduces **which fossil was drawn, how many copies, and the most
that slab could have paid**. All three are integer PRNG draws and arithmetic over constants,
so they port exactly: `make server-golden` asserts 250 seeds across all five sites match
Swift to the dollar.

It deliberately does **not** reproduce bone, rock or gem cell counts, which §6 also asks
for. Those come out of the rasterizer, which runs on 32-bit floats and platform `libm`;
`sin` can differ in the last bit between the client's macOS and the server's Linux, which is
enough to flip a cell on a boundary. An exact test on cell counts would fail for reasons
with nothing to do with cheating, and the ceiling never uses them. The gem count is assumed
to be the maximum, which keeps the ceiling an upper bound.

Getting the arithmetic to agree took one non-obvious step. Swift's content types store
`Float`, so Swift sees `1.6` as `1.60000002384185791015625` while Ruby sees
`1.6000000000000000888…`. The ceiling therefore widens every value to `Double` *before* any
arithmetic, and Ruby narrows each constant to 32 bits as it loads. Without that the two
disagreed by exactly one dollar on Hell Creek slabs — which is what the negative test in the
golden fixture now demonstrates on purpose.

**The ceiling is deliberately generous.** It assumes a flawless dig, every charm the client
claims, every skeleton set complete, and that any rush bonus landed, then allows one percent
plus a dollar. A ceiling that is too loose rejects no honest player and still makes inventing
money impossible. One that is too tight tells a paying customer they are a cheat, which is
unforgivable and cannot be taken back.

## Attestation, honestly

The **assertion** path — the one that runs on every payment — is implemented and tested with
real P-256 keys. A tampered body, a signature from another key, a replayed hardware counter,
a spent nonce, an expired nonce, another install's nonce and a mismatched app id are each
rejected (`spec/app_attest_spec.rb`).

The **registration** path is implemented but has never run against a real device, which needs
a provisioned build and Apple's App Attest root certificate. The root is a configured file
(`config/apple_app_attest_root.pem`, gitignored) rather than something baked in.
`ATTEST_MODE=permissive` exists so the service can be run locally, and it is refused in
production by `AppAttest.required?` rather than by a deploy checklist.

Two things an automated security review caught, both now closed:

- **The relying-party check used to fail open.** An unset `APP_ATTEST_APP_ID` meant "skip
  it", which was an authentication bypass dressed as a development convenience. App Attest
  proves "this is *your* app on genuine Apple hardware"; without that check it proves only
  "this is *some* app on genuine hardware" — which anybody holding an App Attest entitlement
  can produce for an app they wrote, register here, and then use to mint payments
  indefinitely. The signature verifies and the counter advances, because the key really is
  theirs. It now raises whenever attestation is enforced, and a production boot refuses to
  start without the variable set.
- **The authenticator stamp was not checked.** Apple writes `appattestdevelop` into the
  aaguid for a development attestation and `appattest` plus null padding for a production
  one. Accepting the development value in production would let anyone with a dev-provisioned
  build attest a key, which is a far easier bar than App Review and the obvious next way in
  once the relying-party check is closed.

Attestation **fails soft on the client**. App Attest is unavailable on the simulator, on
jailbroken devices, and when Apple's service is down; the request then goes out unsigned and
the *server* decides what to do with it. The policy lives on the server, where it cannot be
edited by whoever is holding the phone.

## The payment queue

Durable, keyed by slab id, and safe to retry:

- **Written to disk on every change**, so a payment survives the app being killed between
  bagging a slab and finding a network.
- **A retry cannot double-count.** `payments.slab_id` has a unique index, and the endpoint
  answers a repeat with the payment that already exists rather than an error — which is
  what makes retrying safe at all. Verified end to end.
- **A refusal is final.** A 422 means the server will never accept that payment, so the
  queue drops it. Keeping it would wedge every later payment behind an item that can never
  clear.
- **Seeds travel as strings.** A seed past 2^53 does not survive a JSON number, and a server
  scoring a different seed would reject an honest payment. Tested with 9007199254740993.

## Three ladders, three homes

| ladder | counts | lives in | why there |
|---|---|---|---|
| **Crew** | every player, against $2.4B | server, `milestones` table | one number nobody's client can know |
| **Outfit** | your group's pooled total | server, `outfit_milestones` | only the server can add up several diggers |
| **Personal** | your own lifetime total | the app, `content.json` | awarded offline from a number the client already has |

That split is the design, not an accident. A cosmetic you earned by digging should not
wait on a network call, and a total spanning other people cannot be computed without one.

## Outfits

A handful of diggers — twelve at most — who pool what they pay. The pooled total counts
**in addition** to the crew debt, never instead of it: a dollar dug pays the Collector
once and shows up in the outfit's total as well.

**"Outfit", not "crew".** Crew already means every player alive against one debt, and it
is spelled that way through the schema, the endpoints, the docs and the fiction. An outfit
is what a survey party was called, which leaves the existing word alone.

**Names are generated, not typed.** Free text would be a content-moderation surface with
no moderation behind it, on a service that stores no accounts and has no way to contact
anyone. Generated names also cannot be squatted or impersonated, and cannot carry a slur
onto a leaderboard every player sees. The cost is real — an outfit cannot be called what
its members want — and it is the reason this is worth revisiting properly with a reject
list and a report path, rather than left as it is.

**Joining is a six-character code**, drawn from an alphabet with no O, 0, I, 1, S or 5,
because codes get read aloud and copied off screens.

**Leaving does not claw anything back.** What a member has already paid stays with the
outfit. Otherwise one person walking out could take a milestone away from everyone else —
and the crew debt itself can never go backwards either.

**Outfit totals move in the same transaction as the payment and the crew ledger**, with
the same `UPDATE … SET paid_total = paid_total + $1` shape, for the same reason: two
members paying at once must both count.

## Keeping the rewards small

Every rung on all three ladders is mostly cosmetic, and the two gameplay perks are a few
seconds of daylight and two percent of payout.

That restraint comes from M3. A reward that makes money easier compounds: more income pays
the debt faster, which reaches the next rung sooner, which grants more income. The
difficulty curve `make simulate` measures would quietly flatten under its own rewards.
`testPerksAreSmallEnoughNotToRebalanceTheGame` asserts the whole personal ladder together
stays under +10% payout and +10 seconds, and changes nothing about cracking.
