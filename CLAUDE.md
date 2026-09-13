# companion — fight parser + session history overlay

Deep combat parser with historical records, rendered as an in-game ImGui
overlay in the **EQ Legends Companion** visual language (palette lifted 1:1 from
jmoyers.github.io/everquest-companion). Runs on emu servers where MQ is allowed.

Run: `/lua run companion` (add `mini`/`full`/`hide` to launch straight into that
mode, e.g. `/lua run companion mini`) · toggle: `/companion` · **compact meter:
`/companion mini`** (double-click the mini window to expand) · quit: `/companion stop`

Two window modes share one render callback (`ui.lua`): `drawFull` (tabbed research
console) and `drawMini` (auto-sizing DPS meter, own window id `###CompanionMini`).
`S.mini` selects; it and window geometry/filters/mode/sort persist in the `pref` table.
**Swap between them** with the `full` button (top-right of the mini header) and the
`compact` button (above the full-view tab bar); `/companion mini` and double-click on
the mini window still work. The chosen mode persists, so it reopens the same way.

## Module map

| File | Role |
|------|------|
| `init.lua`   | Entry point. Startup identity, DB session, wires combat→db→ui, main loop (event pump, zone-flush, history refresh, XP snapshot, prune). |
| `combat.lua` | Capture + encounter engine. `mq.event` patterns → normalized events → gap-segmented encounters → per-source/per-ability rollups + raw event log. `snapshot()` for live UI, `onFinalize(fight)` for persistence. |
| `db.lua`     | lsqlite3 store: `session` / `fight` / `fight_ability` / `fight_cast` / `event` / `death` / `death_sample` / `xp_snapshot`. Batched transactions, prune of raw events, history queries — all scoped to the current server+character via the session table (one shared companion.db across chars). `death`/`death_sample` are never pruned. |
| `ui.lua`     | ImGui render. Live Fight + History views. Hand-drawn DrawList charts + the custom fight-timeline widget. **All DB reads cached in `S` by the main loop — never queried from the render callback.** |
| `group.lua`  | Cross-character DPS sharing over MQ Actors (mailbox `companion_dps`). Each box broadcasts its own current-fight summary ~1 Hz; `freshPeers()` returns peers seen in the last 6s. |
| `export.lua` | Parse export: full multi-line report → timestamped file in configDir, compact one-liner → console. Buttons in Live/History; `/companion export`. |
| `theme.lua`  | Design tokens, ImGui style push/pop, packed-color helper, crash-safe DrawList proxy. |
| `blackbox.lua` | Always-on 2 Hz flight recorder (last 90 s): my HP/mana/aggro/target/ToT/xtargets/casting/flags + group member state + buff drops. Frozen onto the fight on death. `tloReaders()` is the only MQ touchpoint. |
| `postmortem.lua` | Pure analyzer: black-box samples + fight events → verdict (cause class, moments, breakdowns, narrative). `stamp()` caches cause/narrative on the fight before save. |
| `smartheal.lua` | Per-fight rollup of the SmartHeals brain (sidekick-next `ma_healbridge.lua`): decisions from the bridge via actors mailbox `companion_smartheal`, group HP from black-box samples. Pure — no mq, no ImGui, no DB. `stamp(fight)` writes `sh_*` onto the fight beside `Postmortem.stamp`. |

## Conventions / invariants

- **`UI.drawDockedBody()` is cross-script API** — maui (`F:\lua\maui\parse\service.lua`)
  rehosts the whole engine and docks the full-view tabs into its own panel through it;
  it draws into the caller's current window (no Begin/End, `S.open`/mini don't apply).
  Don't rename/remove it or fold the tab bar back into `drawFull`. Never run standalone
  companion on a character running maui — both would parse every combat line and write
  companion.db twice.
- **No yielding or DB work inside the ImGui callback.** `ui.render` only reads `S`.
  History is refreshed from `init.lua`'s loop via `UI.refreshHistory(meta, force)`.
- **The history refresh is gated on `UI.isVisible()`** — it is blocking SQLite on
  the game thread, and on a 14-day DB (~9M `event` rows) `recentDeaths` alone cost
  ~150ms every 2s whether or not anyone had the panel open. Two gates:
  - `UI.drawDockedBody()` / `UI.render()` stamp `UI.markDrawn()`; `isVisible()` is
    "drawn within the last second". Hosts gate drawing differently (standalone
    `S.open`, medley `MedleyParseOpen`, maui's tab), so this is the only portable
    signal — **any new draw entry point must stamp it** or its panel goes stale.
  - Inside `refreshHistory`, `recentDeaths` + the two aggregates run on a 10s slow
    tier; only `recentFights` runs at the caller's cadence. Pass `force` (the
    loops pass `needRefresh`) to serve a just-finished fight immediately.
  Anything reading `S.hist.*` from outside render must cope with a cold cache —
  see `UI.exportDeath()`, which queries the DB directly when the list is empty.
- **`event` needs `idx_event_kind_fight`** (`kind, fight_id`). `recentDeaths` looks
  for ~400 `kind='death'` rows among millions; without it SQLite walks every event
  row of every fight (measured 165ms → 0.4ms on a 9M-row DB). It is built by
  `DB:_ensureKindIndex()`, **not** by the `SCHEMA` blob: on a large DB the build
  takes ~15s holding the write lock, which would blow past every other boxed
  client's 750ms `busy_timeout` and fail their whole multi-statement schema exec,
  not just that statement. Same reasoning applies to any future index on a big
  table — check first, announce, and let a BUSY loser skip. To skip the in-client
  pause, run `/lua run companion/tools/build_kind_index` with everyone logged out.
- **DrawList via `Theme.drawlist(dl)` only** — MQ's ImDrawList methods take
  **ImVec2 parameters** (`_ImDrawList.lua` definitions); raw coordinates ERROR
  (silently, under pcall — everything just doesn't draw). But on some builds
  `ImVec2()` returns a Lua table that crashes them (`group/DRAWLIST_NOTES.md`),
  so the proxy tries ImVec2 first, falls back to raw, and caches the mode.
- **`ImGui.Selectable(label, selected, flags)` returns `(selected, clicked)`**
  — read the SECOND return for the click. Reading the first makes the
  already-selected row "click" itself every frame, stomping real clicks
  (this bug froze history fight selection once).
- **Vector-returning ImGui calls give plain numbers here**
  (`GetContentRegionAvail`, `GetCursorScreenPos`, `CalcTextSize` → `x, y`). The
  `*Vec` variants return ImVec2; we don't use those.
- **Event dedup:** first-person (`You ...`) and third-person (`#1# ...s ...`)
  patterns can both match your own lines; `outgoing()` early-returns on
  attacker `You` so damage is counted once.
- **Hit modifiers** (`combat.lua:parseModifiers`, taxonomy from EQLogParser):
  the trailing `(...)` is parsed into a flag set — crit (Critical / Crippling
  Blow / Deadly Strike / Finishing Blow), lucky, twincast, flurry, rampage,
  riposte (suppressed if strikethrough), slay undead, assassinate, headshot,
  double bow. Per-ability counts accumulate in `a.mods`, persist as a compact
  `"k:v,k:v"` string in `fight_ability.mods`, and show in the breakdown as
  `N% crit · N flurry · N riposte · …`. Add a modifier by extending
  `MOD_KEYWORDS`; the DB/UI need no change.
- **Cast tracking** (`combat.lua:recordCast`/`buildCasts`): captures the full
  cast funnel per caster+spell — `You begin casting/singing X` (+ third-person),
  `Your X spell fizzles!`/`is interrupted.`/`did not take hold` (+ third-person
  fizzle/interrupt), and activations (`You activate X.` / `<N> activates X.`,
  disciplines/AAs). Casts never refresh the fight clock (`ensureActive(false)`)
  so buffing can't hold an encounter open; pure-cast encounters (no damage,
  no deaths, no heals) are shown live but not persisted. Spells are classified
  by observed behavior (`classifyCast`): ability row kind heal→'heal',
  nuke/dot→'damage', activations→'activate', else 'other' (buff/utility).
  Persisted in `fight_cast`; rendered as the "Casts" card (live) and under the
  history breakdown.
- **Heals are per-spell with overheal** and are excluded from damage totals:
  `You healed <tgt> for N (M) hit points by <Spell>` → ability row keyed by
  spell name, effective N, `over = M-N` (persisted as `fight_ability.over_total`,
  fight-level `heal_total`/`overheal`). The no-`(M)` pattern's handler skips
  `(M)` lines (both patterns match those — that's the expected
  `my_heal+my_heal_over` overlap in the validator). Heals previously leaked
  into DPS totals — fixed; `record()` returns early for kind='heal'.
- **Pet ownership** (`combat.lua:classifySource`/`resolvePet`): pet given-names
  come from a shared random pool, so keying by name collides across owners.
  Combat text usually prints the owner (`` <Owner>`s pet ``) — parsed directly;
  a bare pet name falls back to `Spawn(name).Master` via the `getMaster` TLO
  callback (best-effort, may be nil if out of range). Pets normalize to
  `` <Owner>`s pet `` so reused names never merge. `myPet` (mine) counts toward
  your DPS (`petDmg` + the you+pet line); other players' pets go to `otherDmg`.
  Both are flagged `isPet` for blue coloring, and `is_pet` is persisted per
  ability row. Cache is cleared on zone (names recycle).
- **SmartHeals feed is one-way and local.** `ma_healbridge.lua` fans `config`/
  `decision`/`ack`/`veto`/`net` messages to `companion_smartheal` across the
  host scripts, the same fan-out `group.lua` uses for `companion_dps` — an
  address-less send only reaches the sender's own script. Companion never
  replies. No bridge means no messages, and the Healing tab's SmartHeals cards
  simply do not render. `smartheal.lua` must stay free of `mq` so its test runs
  under plain luajit.
  **`Smartheal.snapshot()` is read-only to callers.** It is cached and handed
  out again on later frames, and its `tiers`/`results`/`decisions` fields are
  live references into the accumulator's bucket -- only `members` is a fresh
  array. Sorting or clearing one of them in place corrupts the accumulator, not
  just your view; build a local array and sort that (`ui.lua` drawHealing does).

## Group sharing (group.lua)

Every companion instance broadcasts its OWN player+pet damage AND heal totals to
the `companion_dps` actor mailbox at ~1 Hz (live fights only); the mini meter
merges them **by name** with the local parse — a peer's first-person report is
authoritative and OVERRIDES the local third-person estimate for that name (no
double count), while mobs / non-companion players I only see third-person fill
the rest. Peer rows are marked with a green `*`. The mini meter has a **dps/hps
toggle** (`S.miniMode`) so it works as a group damage OR healing meter. The full
Live tab shows a **Group card** (right column) that surfaces each fresh peer's
complete broadcast — dmg/pet dps, pet name, hps, and current target — plus a
group-total header (my live dmg/heal dps + every peer's). That's the whole
drill-down available: we deliberately broadcast only a per-peer summary, never a
peer's event log or per-ability rows, so there's nothing deeper to expand.
Sharing is user-toggleable at runtime via `G.setEnabled(bool)` (Settings tab →
`G.on`); when off, `broadcast`/`freshPeers` no-op and peers clear.

## Settings (Settings tab)

Runtime tunables live in `S.settings` and persist as `set_*` pref keys
(`loadPrefs`/`savePrefs`). Each applies live — no reload:
- **timeout** → `Combat.timeoutSec` (encounter close gap, combat.lua:19/836).
- **retentionDays** → `init.lua` prune loop via `UI.retentionDays()` (raw events
  only; fight/ability rollups are kept forever).
- **miniRows** → `drawMini` row cap.
- **share** → `Group.setEnabled` (group-sharing on/off).
The tab also has a **Reset window position/size** button (sets `S._win` +
`S._winApply`, consumed by the geometry-apply path in `render`).

## Healing (Healing tab)

Heals are captured for ALL healers: my own (`cmp_my_heal*`) plus other players
(`cmp_ot_heal*`, reflexive himself/herself → healer; `isMe` guard prevents
double-count; passive `X has been healed` with no healer is skipped). Per-healer
totals live in `enc.healBy` (+ overheal from the `N (M)` split). `snapshot`
splits abilities into damage (`abilitiesBySource`) vs heal (`healAbilitiesBySource`)
so neither view shows the other's rows, and exposes `healSources` (ranked healer
meter with hps/activeHps/overpct). The **Healing tab** = healer meter + selected
healer's per-spell breakdown (overheal per spell). **Full-overheal ticks log as
`for 0 (M)`** — record() handles heals BEFORE its `amt<=0` bail so those still
count (often 99%+ of a HoT), but they're kept out of the event log to avoid
flooding the cap; ability filters include `(a.over or 0)>0` so a pure-overheal
spell still appears. **Silent HoT ticks** (a HoT tick into a full bar prints NO
line, not even `for 0`) are inferred: `cb.spellDuration` gives ticks-per-cast
(6s each) via sidekick-next's proven pattern — `Me.Spell(name).MyDuration()`
(focus/AA-adjusted) with base `Spell(name).Duration()` fallback; `expected = casts * ticks`,
`wasted = expected - logged`, `wastedHeal ≈ wasted * avg-tick`. Shown as
`N/M ticks · ~X silent`. It's an ESTIMATE (conflates silent-overheal with
refresh-clipping; needs cast data so it self-scopes to our own HoTs). Group HPS
flows through the
same actor broadcast as damage.

## Hit-size distribution, Overall toggle

- **Percentiles**: each damage ability keeps a log-bucketed hit-size histogram
  (`bucketOf`, base 1.3, O(1)/hit), persisted as `fight_ability.hist` (same "k:v"
  encoding as mods). UI computes median/p90 from it (`histPercentiles`) — shown in
  the breakdown, works live + history.
- **Overall/zone toggle** (`S.liveScope`): a `Fight|Overall` switch in the Live
  summary. `combat.mergeIntoOverall` folds every finalized fight into a running
  zone accumulator (reset by `M.zoned()` on zone change); `M.overallSnapshot()`
  reuses `buildSnapshot` with summed fight-time as duration (cached via
  `overallRev`). Overall hides the per-second chart/timeline (per-fight only).

## Defensive / avoidance

Avoidance IS log-derivable (unlike AC mitigation). `cmp_in_miss`
(`<mob> tries to <verb> YOU, but <outcome>`) classifies the outcome into
miss/dodge/parry/riposte/block/rune (`enc.avoidBy`); landed melee swings are
counted in `enc.incMeleeHits`. `snapshot.avoidance` = `{swings, landed, avoided,
pct, by}`, shown in the Live Incoming card (`N% avoided` + per-type). Ceiling:
AC **mitigation** (damage soaked) is invisible — the log only prints the
post-mitigation number.

## Deaths / post-mortem

`Combat.recordDeath(killer)` is the single death entry point: "You have been
slain by X!", "You died.", and the black-box `Me.Dead` edge (init/service
main loop) all route through it; calls within 5 s collapse into one death
(a later call only back-fills an unknown killer). Each death freezes
`blackbox:freeze()` onto `enc.deathRecords` → `fight.deaths_detail` →
`death` + `death_sample` tables (never pruned). Both `init.lua` and
`service.lua` call `Postmortem.stamp(fight, playerName)` before
`db:saveFight` so the list badge/export have a cached cause; the Deaths tab
re-runs `Postmortem.analyze` on selection (in `refreshHistory`, never in
render) so older deaths benefit from analyzer changes. Cause rules live in
`postmortem.lua:analyze` in the spec's order (environmental → cc → burst →
noheals → aggro → overwhelmed → dot → sustained → unknown); each has a
scenario in `tests/test_postmortem.lua`. New event kinds: `wornoff`
(`Your X spell has worn off.` — self buffs only; other buff fades are
detected by the `CountBuffs` diff in blackbox) and `castfail`
(fizzle/interrupt/blocked, mine and others'). `/companion death` exports
the selected (or latest) death to console + `companion_death_<char>_<ts>.txt`.
Legacy deaths (no `death` row) still list and show the old final-blows recap.

## Known ceiling (log-capture tier)

Pure chat parsing cannot see raw-vs-mitigated damage, overheal, or absorbs, and
third-person **crit** attribution is best-effort (crit line correlated to the
next of your hits within 0.6s). This is the robust, patch-proof tier. A future
C++ color-channel source could call `combat.record()` with higher fidelity
without changing the engine, DB, or UI.

## Verified vs unverified

- **Syntax**: all modules parse clean (luaparser).
- **Combat patterns: log-validated.** Patterns were validated against real logs
  in `B:/eq/logs` by translating each `mq.event` pattern to regex and replaying
  **~1.5M in-scope combat lines** across teek/frostreaver/antonius characters
  (frostreaver raids are the most-progressed content on disk): **100% in-scope
  coverage** (in-scope = this char's outgoing damage, pet/group damage, and
  incoming to me — including **incoming DoT**, `You have taken N damage from X`).
  Multi-pattern check: the only overlap is `my_spell`/`ot_spell` on your own
  `You hit …` lines, which `ot_spell` early-returns on (attacker `You`), so **no
  double counting**. (No mischief-server logs exist locally; frostreaver raid
  logs cover the higher-tier damage types instead.)
- **Client specifics captured** (modern EQ / Teek-era): crits are same-line
  suffixes `(Critical)`/`(Riposte Critical)`; spell/proc damage is
  `You hit X for N points of <element> damage by <Spell>`; DS is
  `X is <verb> by YOUR/<Owner>'s <element> for N points of non-melee damage`;
  heals are `You healed X for N [(M)] hit points by <Spell>`; pets render as
  `` <Owner>`s pet ``; third-person **spell** uses singular `hit`, melee uses the
  pluralized verb.
- **Deliberately out of scope** (left unmatched): other players' heals, DoTs
  printed without a caster (`X has taken N damage by <Spell>`, or a blank caster
  `... from <Spell> by .` — damage on others), and unattributable frost DS
  (`chilled to the bone`, no owner). Rune/absorb lines are mitigation (damage
  prevented), not dealt damage — also out of scope.
- **Still unverified in-game**: the record→aggregate→persist→render path end to
  end (encounter segmentation timing, DB writes, UI). Take a fight and sanity-
  check the breakdown totals against the native combat log.

Pre-launch lint (RUN AFTER EVERY EDIT): `python tools/lint.py` — catches the two
crash classes `luaparser` parse can't: undefined-name references (leftover after a
refactor, e.g. `colW`) and use-before-definition of a file-scope `local function`
(e.g. `parseModifiers`). Both bit us repeatedly; this is the cheap net. Must print
"all clean" before reloading in-game.

Validation harness: `tools/validate_patterns.py <logfile> [maxlines]` — replays
a real log through the (regex-translated) pattern set and reports in-scope
coverage + multi-pattern matches. Keep its PATTERNS list in sync with
`combat.lua:registerEvents()` and re-run after any pattern change or on a new
server whose combat text may differ.
