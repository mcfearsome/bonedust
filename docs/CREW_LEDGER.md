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
