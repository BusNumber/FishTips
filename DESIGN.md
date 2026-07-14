# Fish & Tips — Design Notes

This document explains **what** Fish & Tips does and **why**, how the code is structured,
and the WoW API landmines the implementation steps around. It is the **living** design
doc — if you're about to change behavior, check here first.

> **Status:** early release. **Retail only** (Midnight, 12.0.x). The API behaviors this
> document relies on are confirmed against the in-game acceptance checklist in
> [CONTRIBUTING.md](CONTRIBUTING.md); anything not yet runtime-verified is called out inline.
>
> **Build state:** the presentation layer (the stats window, settings, minimap, slash
> commands) is implemented and reads through the `ns.Get*` seams. Now wired:
> the **double-right-click cast**, **cast counting**, **loot-driven catch recording**
> (LOOT_READY-first, once per window, gated to fishing, keyed by itemID), **auto-opening
> the window when fishing starts**, **fishing-only auto-loot** — the loot reader calls
> `LootSlot()` to grab the catch (gated by the `autoLoot` setting, default on) — an
> **Auctionator price overlay** (session gold values, on by default but only rendering when
> Auctionator is installed), and **smart sessions** (configurable auto-end judged lazily at
> the next cast, an active-time clock that pauses during breaks, a whole-session catch
> list, `/reload` persistence, auto-hide for auto-opened windows — see *What it does* §5),
> and an **Addon Compartment entry** (the default access path; the custom minimap button
> is now opt-in, default off — see the API notes).
> A **LuaJIT test harness** (`tests/`, run in CI) asserts the
> data-layer invariants out of game. Still roadmap: **junk auto-discard** (auto-selling or
> throwing back gray catches — see Deferred/roadmap).

## Why this addon exists

The historic retail catch-trackers have gone unmaintained on Midnight (their last builds
predate 12.0.x and are flagged out of date). The live fishing addons that remain are casting
quality-of-life tools: they make casting one button, but they don't track *what* you catch or
*where*. And no addon currently does **fishing-only auto-loot** well on modern retail (the
dedicated options are stale; the popular ones defer to a second addon).

Fish & Tips fills that gap: a maintained **per-location catch tracker** with an
**integrated fishing-only auto-loot**, plus the classic **double-right-click cast** for
players who prefer click-the-water over soft-targeting.

## The core data facts

Everything rests on a few facts about how fishing surfaces to addons:

- **There is no bite/splash event.** The game never tells an addon "the bobber splashed."
  So Fish & Tips **never tries to detect the bobber** — *the player clicks it.* We react
  only to what a successful catch produces: the loot window. (Anything that claims to
  detect the splash is doing out-of-game audio detection, which is against the ToS — we
  don't go there.)
- **A catch is a loot event.** Looting a fished bobber fires the standard loot events
  (`LOOT_READY` / `LOOT_OPENED`) with readable loot slots. That is both our catch signal
  and our data source.
- **Protected actions need a hardware event.** Casting, using items, and equipping gear are
  protected — an addon drives them through a `SecureActionButtonTemplate` in response to the
  player's own click/keypress, never silently on a timer or `OnUpdate`. This is *why* the cast
  is a double-click, not an automatic loop, and why there is no "AFK fishing" here.
- **Looting is the exception that makes auto-loot possible.** `LootSlot()` is *not* one of the
  secure-button actions above — it is callable from the insecure `LOOT_OPENED` handler (the
  bobber click that opened the window is the hardware event). So grabbing a catch needs no
  secure frame; it still can't run on a timer, because there is no loot window without the
  player's click. This is the bedrock the fishing-only auto-loot stands on.

## What it does

### 1. Cast Fishing (keybind and/or double-right-click)
A `castMode` setting picks how you cast: **double-right-click** (the classic click-the-water
style some anglers prefer — a clean differentiator), a **keybind**, **both**,
or **off** (the default). Casting is a protected action, so it is always driven by a real
hardware event through the **secure binding system**, casting Fishing **by name** — the player's
key, or a brief `BUTTON2` override armed by the second of two quick right-clicks. There is deliberately
**no frame over the world** (that breaks hover/mouselook — see the API notes).

### 2. Per-location catch tracking
Every catch is logged by **zone + subzone**, with **current-session** and **lifetime**
totals, **per character** plus an **account-wide rollup** (surfaced in the UI as
**"Warband"**, the retail term). Casts are counted too (from the fishing spell events),
giving a fish/hour rate. A movable stats window — toggled by a slash command, the
minimap's **addon compartment** entry, or an opt-in minimap button (`showMinimap`,
default off; the compartment is the default access path) — shows the breakdown, with the
current zone/subzone highlighted.

Display decisions (presentation only — they don't change the data): the window has a
**Session / Lifetime** toggle, and the **character / Warband scope selector appears only in
the Lifetime view** — a session is inherently the current character, so there is nothing to
scope. The converse control, a **"New session" reset button, appears only in the Session
view** (it pops a `StaticPopup` confirmation — guarding against an accidental wipe — that on
accept calls `ns.ResetSession`). Each catch row shows the **rarity-colored item name**
(poor-quality junk is dimmed well below the normal-item text so it visibly recedes), a thin
**frequency bar**, the **count**, and the count's **share %** of the list's catches. The
catch list's scope differs by view: **Session lists the whole session** — everything caught
this session, merged across locations, so a pool-hunter's list doesn't empty out when they
fly to the next pool — while **Lifetime filters to the current zone/subzone**. A
**location header** names the current zone/subzone (catch counts are carried by the
catch list and the **footer stat bar** — `casts · catches · /hr · minutes` — so the
header itself stays uncluttered).

The **`includeJunk`** account-wide setting (default on) decides whether gray (quality-0)
catches appear at all. With it off, junk is dropped from the list **and** every total (the
footer counts, the rate, the top-zones chart) — but it is still **recorded**, so toggling it
back on restores the history. The filter is **display-time only**: it lives in the read seams
(below), nothing in the write-path or DB schema changes, and so it does **not** bump
`DB_VERSION` (additive boolean, `== nil` default-filled, sanitized to a boolean). Junk is just
`quality == 0` (already stored per catch); items with no recorded quality count as non-junk.

### 3. Fishing-only auto-loot — the *same* mechanism as tracking
This is the key design insight. When fishing loot becomes available, Fish & Tips reads
every slot (recording each catch into the tracker) and then loots all of it — one handler
walking the slots **in reverse** (looting re-indexes the list) and calling `LootSlot()` on
each. The handler runs at **`LOOT_READY`** — which fires *before* the loot window shows,
ahead of external fast-loot addons (they can finish looting before `LOOT_OPENED` ever
fires) — with `LOOT_OPENED` as the fallback, and a **once-per-window guard** (cleared at
`LOOT_CLOSED`, and on the next cast as a backstop) so the two events never double-count a
window. Because we read at the earliest addon-visible moment and do the looting ourselves,
**the recorded counts stay exact whenever Fish & Tips or the game's own auto-loot grabs the
catch** — sidestepping the classic catch-tracker bug where a separate "fast loot" addon
grabbed the fish before it could be counted. (Against a third-party fast-looter racing the
same `LOOT_READY` event, recording is best-effort — that event is the earliest point any
addon can act.) When the game's **native auto-loot** is doing the looting (the loot events
carry that flag), Fish & Tips records but skips its own `LootSlot()` pass — the client is
already grabbing every slot. Non-fishing loot (mobs, chests, herbs) is never touched: the
gate is `IsFishingLoot()`, with a short-window-after-cast heuristic as fallback.

Auto-loot is gated by the **`autoLoot` setting** (default on), read live on each catch.
Tracking does not *require* it — with `autoLoot` off, Fish & Tips still reads the loot
slots to record the catch without looting anything.

A whole window is recorded in one pass and the UI repaints **once** per window, not once
per fish.

### 4. Auctionator price overlay — for people who fish to sell
A **display-only** overlay (`auctionatorPrices` setting, **on by default** — but it only ever
renders when Auctionator is installed, so it's harmless for everyone else) that answers "how
much have I made this session?" while you're still fishing. When on **and Auctionator is
installed**, the stats window shows, **for the current session only**: next to each fish, the
value of your catch — `count × unit auction price` — in parentheses (`N 🪙`, or `? 🪙` when
Auctionator has no data for that item); and a right-aligned **session total** (whole session,
all zones) in the footer stat bar and the compact strip. The number leads, the gold icon
trails (`N 🪙`). Prices are **floored to whole gold** (silver/copper dropped —
`floor(copper / 10000)`).

> **Scaffolded but deferred:** a precision picker (`priceDetail` = `gold` | `goldsilver` | `all`)
> is partly in place — the UI's single `goldStr` money-format helper already branches on the
> setting (gold-only, +silver, +silver+copper, each with its own coin icon), and the additive
> account-wide enum is sanitized like `includeJunk` (**no `DB_VERSION` bump**). It needs more
> thought before shipping, so the **options dropdown is intentionally not registered** and the
> sanitizer **pins `priceDetail` to `"gold"`**, leaving today's gold-floored behavior unchanged.
> Re-enabling it means restoring the validation clamp in `applyDefaults` and registering the
> dropdown (nested under the "Show Auctionator prices" checkbox).

Prices are **never recorded** — they're read live from Auctionator and so are never persisted,
versioned, or migrated. Lifetime view shows no prices (lifetime price data goes stale). The
overlay honors the `includeJunk` filter: a hidden gray fish's value is excluded from the total
too, so the number stays consistent with the visible list. Like `includeJunk`, this is an
additive account-wide boolean — **no `DB_VERSION` bump**, nothing in the write-path or schema
changes. All Auctionator access lives in the data layer behind the `ns.Pricing*`/`ns.Get*Price`
seams; the UI never calls Auctionator directly. (Integration mechanics are in the WoW API
notes.)

### 5. Sessions that end themselves (and a clock that pauses)

A "session" is not login-to-logout. Three behaviors, all account-wide settings, all
additive (`== nil` default-filled and sanitized — **no `DB_VERSION` bump**):

- **Auto-end (`sessionEnd`, default `"idle"`).** When does the next cast begin a *new*
  session? `manual` (never — only the "New session" button), `idle` (more than
  `sessionIdleMinutes` — default 30 — since the last cast), `zone` (the zone changed since
  the last cast), or `zoneidle` (**both** — so an AFK return to the same spot continues).
  **Boundaries are judged lazily, at the next cast** — never by a running timer or a zone
  event — so a finished session stays readable on screen until fishing actually resumes,
  and no plumbing watches the clock or the map. When a session ends itself (and it had
  catches), one chat line summarizes its final tally; the manual button prints nothing
  (the player asked for it).
- **The active-time clock (`sessionPause` default on, `sessionGraceMinutes` default 5).**
  Session time is an *accumulator*, not a start timestamp: each between-cast gap counts
  toward elapsed only up to the grace (`activeTime += min(gap, grace)`; the live tail since
  the last cast is capped the same way, so the footer clock visibly freezes at
  `activeTime + grace` while idle). A pool-hunter's 2–3-minute flight between pools counts
  in full — search time is fishing time — while a dinner break adds at most the grace, so
  fish/hour stays honest for both playstyles. Turning the pause off restores wall-clock
  counting (the cap becomes infinite). Elapsed is zero before the first cast: the clock
  starts when fishing does, not at login.
- **`/reload` persistence.** The live session struct is linked by reference into the DB as
  a **disposable snapshot** (`db.chars[key].session` — see *DB schema*), so it serializes
  at logout/reload with no explicit save step. At login it is sanitized and restored, and
  the reload gap is judged by the same end rules: the idle half right at restore (a
  week-old session doesn't greet the player at login), the zone half at the next cast
  (the current zone isn't reliable at login). Under `manual`, a session deliberately
  survives `/reload` — and even a logout — until the button resets it; that is the
  coherent reading of "manual".

And the symmetric half of auto-open — **auto-hide (`autoHide`, default on).** When the
session *pauses* (the grace elapses after the last cast), a surface that **auto-open showed
and the player never touched** tucks itself away; the next cast brings it back via
auto-open. The exemption is what makes default-on safe: a manually-opened window is never
hidden, and any interaction with an auto-opened surface (a drag, any control click)
promotes it to player-owned (`UI.autoShown` is cleared). A surface under the mouse is
skipped — it's in use; the next fishing stop re-arms the pause — and `uiShown` is never
persisted, exactly like auto-open. This is the **one deliberate timer** in the session
model (a pause must *act* at a moment; every boundary is judged lazily): Core arms
`C_Timer.After` at `UNIT_SPELLCAST_CHANNEL_STOP` for the remainder of `lastCast + grace`,
cancels it via a generation token at the next cast (`C_Timer.After` has no cancel handle),
and fires the `ns.RegisterSessionPause` notifier the UI subscribes to. The notifier itself
keys off `sessionGraceMinutes` and fires regardless of the `sessionPause` checkbox (Core
stays a generic seam — the checkbox governs the elapsed-time arithmetic), but the UI's
auto-hide subscriber acts only when **both** `autoHide` and `sessionPause` are on: in the
options panel, **Auto-hide stats window** and **Pause after** are nested under **Pause
session when not fishing** and gray out when it's unchecked — with the pause off there is
no pause moment, so the gray-out must be truthful (no lying disabled states).

## Architecture

```
### FishTips.toc
Manifest. `## Title: Fish & Tips`, `## SavedVariables: FishTipsDB`.
Loads Locale.lua, Core.lua, Casting.lua, UI.lua, Settings.lua (order matters).

### Locale.lua
Localization scaffold, loaded FIRST so every file can reference it. `ns.L` maps English
keys -> translated strings with an identity fallback (a missing key returns itself), so
English needs no table and a missing translation can never break a render. User-facing
strings go through `ns.L["..."]`; format strings are wrapped whole (`ns.L["+%d more"]`)
so translations can reorder words. Excluded on purpose: the "Fish & Tips" brand, slash
tokens and token-list help, dev-only output (/ft demo, /ft castdebug), texture paths.

### Core.lua
Data layer: SavedVariables DB + fishing-state detection + loot read/auto-loot +
zone resolution + the catch store + session semantics (boundaries, the active-time
clock, the pause notifier) + account rollup. Owns the `ns.Get*` seams.

### Casting.lua
The cast triggers. The cast is a protected action and is driven through the **secure binding
system, casting Fishing by *name*** (`SetOverrideBindingSpell`) — the same resolution the working
`/cast Fishing` macro uses. There is **no secure action button** (`type="spell"` →
`CastSpellByID/Name` and `type="macro"` → `macrotext` both silently no-op for this profession
spell on 12.0) and **no frame over the world**. Two paths, gated by `castMode`:
- **Keybind** — the player's "Cast Fishing" key ([Bindings.xml](Bindings.xml)) is override-bound to
  cast by name: `SetOverrideBindingSpell(keyOwner, true, key, <localized name>)`, (re)applied out of
  combat; the binding body re-applies it if cleared.
- **Double-right-click** — detected via the **`GLOBAL_MOUSE_DOWN` event** (NOT
  `WorldFrame:HookScript`, which taints the cast); two quick right-downs arm a **one-shot**
  `SetOverrideBindingSpell(dblOwner, true, "BUTTON2", <name>)` so the second release casts, then a
  short `C_Timer` clears it. Arming only mid-double-tap keeps the camera intact.

Keybind and double-click use **separate override owners** so clearing the transient one never
disturbs the persistent one. All binding changes happen out of combat (login, dropdown change,
`PLAYER_REGEN_ENABLED`). Isolated on purpose — secure/taint-sensitive, kept out of data logic.

> **Lesson (three regressions):** (1) a mouse-enabled frame over the world eats mouse *motion*
> (no API forwards motion to `WorldFrame`) so the **hover outline dies**; with
> `SetPassThroughButtons` the click goes to the world so the **cast never fires**, and plain
> `SetPropagateMouseClicks` never reaches the world frame so it **breaks mouselook**. Never cover
> the world with a mouse frame. (2) Arming the right-button override-binding on the **first**
> click (and leaving it set for the whole window) hijacks the next right-hold and eats the
> button-up → **stuck character-rotate**. The fix: hook `OnMouseDown`, arm **only on the second
> down** of a quick pair, and clear in `PostClick`, so the binding lives ~one click and lone
> clicks/holds never see it. The working cast uses no world overlay — a keybind and/or this
> non-consuming-hook + one-click override-binding (the standard open-source idiom). (3) Setting
> the `type`/`spell` secure attributes in an insecure `PreClick` — i.e. *during* the click that
> casts — **taints the protected cast, which WoW silently blocks** (both paths cast nothing, no
> error). Set attributes at setup / in `ApplyMode` **out of combat**, never on the click path.
> (4) For the Fishing profession spell on 12.0, **`CastSpellByID`/`CastSpellByName` and a secure
> button's `macrotext` all silently no-op** — only `/cast <name>` resolves it. So the cast button
> was dropped entirely in favor of `SetOverrideBindingSpell` (cast **by name**), the same path
> `/cast Fishing` uses. (5) `WorldFrame:HookScript` taints the secure cast (it no-ops even with a
> correct binding); detect the double-click via the **`GLOBAL_MOUSE_DOWN` event** instead.

### UI.lua
Presentation: the movable stats window (Session/Lifetime + a Session-only "New session"
reset, a location header, per-location catch list, top-zones chart, footer stat bar), a
**compact minimized strip**, the **Addon Compartment handlers** (the drawer entry is the
default access path — see the API notes), a custom minimap button (opt-in, default off;
its ring radius derives from the live minimap size and re-places on `OnSizeChanged`),
and a small **theme engine** — a registry of palettes + body layouts applied by
`ApplyTheme`. The theme engine is currently **locked to a single look** (no chooser is
exposed) but kept in code for future customizable themes. Reads only via `ns.*` seams.

Render model: WoW never garbage-collects Frames/Textures/FontStrings, so the themed body
is drawn from small **manual widget pools** (re-parented on acquire) — a rebuild releases
and re-acquires the same widgets instead of destroying anything. Refreshes are
**coalesced**: data events schedule one flush on the next frame (`C_Timer.After(0)`),
visibility is decided at flush time, and only the **visible surface** repaints — with just
the compact strip up, the hidden window is skipped and simply repaints on show (every show
path calls `UI.Refresh`). The zone chart's data walk is skipped in views that don't
render it. The window chrome (title bar, controls, dropdown, compact strip, minimap
button) is built once and never rebuilt.

### Settings.lua
Settings layer: defaults/sanitizing for `db.settings`, the options panel, the slash
command(s). Owns `ns.InitSettings`, `ns.GetSettings`. The panel is built with the **modern
Settings API** (`Settings.RegisterVerticalLayoutCategory` + `RegisterAddOnSetting`), so the
controls match current Blizzard options pages and inherit the native **"Defaults"** button
(it resets every registered setting because each one is bound to `db.settings` by key, with
its default and `type()` supplied at registration). Side effects on change are wired via
`Settings.SetOnValueChangedCallback` (e.g. cast mode → `ns.Casting.ApplyMode`, minimap →
`ns.UI.SetMinimapShown`). A footer shows the donate link (from the TOC `X-Donate`, scheme-
stripped — no field, no line) and the addon version. Registration happens once, at the end of
`ns.InitSettings`, so the bound `db.settings` table is never replaced afterward.
```

Files share the private addon table via the `local addonName, ns = ...` vararg. **Keep
the data/presentation split**: new data sources go in the data layer; `UI.lua` reads only
through the `ns.Get*` seams. Start-up hand-off: Core's
`ADDON_LOADED` handler initializes the DB then calls `ns.InitSettings(db)`;
`ns.GetSettings()` returns nil until then and callers treat nil as default behavior.

### Data seams (UI ↔ Core)

`UI.lua` calls only these read seams; `Core.lua` derives them from the DB (the account /
Warband rollup is computed here at display time, so the *account = Σ characters* invariant
can't be broken by a render path):

- `ns.GetCurrentLocation()` → `{ zone, subZone, isSpecialPool, mapID }`
- `ns.GetScopes()` → ordered `{ key, name }` list, ending in `{ key = "account", name = "Warband" }`
- `ns.GetTotals(scope, mode)` → `{ casts, catches, ratePerHour, elapsed }` (`mode` = `"session"` | `"lifetime"`)
- `ns.GetZoneTotals(scope, mode)` → catches-desc `{ {zone, catches}, … }`
- `ns.GetLocationItems(scope, mode, zone, subZone)` → count-desc `{ {itemID, name, link, quality, count}, … }`
- `ns.GetSessionItems(scope)` → the same row shape, but the **whole session** merged across
  every zone/sub — the Session view's catch list (see *What it does* §2/§5)
- `ns.GetSessionScope()` → the scope that owns the live session (the current character)

The catch-counting seams (`GetTotals`, `GetZoneTotals`, `GetLocationItems`,
`GetSessionItems`) apply the `includeJunk` display filter here, in one place: `sumItems`
(shared by the totals and zone rollups) and the item-list seams skip quality-0 items when
`includeJunk` is off, so the list and every total stay consistent. Filtering lives in the
data layer, not the UI.

The optional Auctionator price overlay adds three read-only pricing seams (also data layer —
the UI never touches Auctionator):

- `ns.PricingActive()` → `true` only when the `auctionatorPrices` setting is on **and**
  Auctionator's `API.v1.GetAuctionPriceByItemID` is present. The single gate the UI checks.
- `ns.GetItemPrice(itemID)` → unit market price in **copper**, or `nil` when pricing is off or
  Auctionator has no data for the item (→ the `? 🪙` state).
- `ns.GetSessionValue()` → total **copper** of the current session's catches (`Σ count × unit`
  across all zones), or `nil` if pricing is off; skips items with no price and honors
  `includeJunk`.

The tracking write-path (see the WoW API notes) feeds the same store these seams read:

- `ns.RecordCast()` — increment the cast counter (lifetime + session) for the current char.
  Also the **session-boundary judge**: before counting, it applies the `sessionEnd` rule to
  the gap/zone since the previous cast (*What it does* §5) and starts a fresh session when
  the rule says so, then accumulates the capped gap into the active-time clock.
- `ns.RecordCatch(itemID, count, name, quality, link)` — record one fished item, keyed by
  itemID, tagged with the current real zone/subzone (and their raw mapID — see *DB
  schema*), into both lifetime and session.
- `ns.ResetSession()` — drop the current character's session store, in memory and its
  persisted snapshot (the Session "New session" button); the elapsed clock reads zero until
  the next cast. The persisted lifetime history is never touched; fires a refresh.
- `ns.RegisterFishingStart(fn)` / `ns.FireFishingStart()` — a notifier (parallel to
  `RegisterRefresh`/`FireRefresh`) the UI subscribes to so it can **auto-open** the window
  when fishing begins. `FireRefresh` only repaints an already-open window; this can show it.
- `ns.RegisterSessionPause(fn)` / `ns.FireSessionPause()` — the converse notifier: fired
  once when the session goes idle (the pause grace elapses after the last cast with no new
  one). The UI subscribes to **auto-hide** an auto-opened surface; this must be able to
  *hide* one, which `FireRefresh` can't.

The loot reader does both jobs from one handler registered for `LOOT_READY` **and**
`LOOT_OPENED` (whichever fires first wins, via a per-window guard cleared at `LOOT_CLOSED`;
gated to fishing): it reads each item slot into the store, and — when the `autoLoot`
setting is on and the client isn't already native-auto-looting — calls `LootSlot()` to
grab the catch. It walks the slots **in reverse** and reads each slot's info **before**
looting it (a looted slot re-indexes the list and clears its link/info), then fires ONE
refresh for the whole window (not one per item).

## DB schema

```
FishTipsDB = {
  version = 1,
  addonVersion = "<TOC version string>",        -- write-only diagnostic, never read
  settings = { ... },                           -- account-wide: behavior + display
  chars = {
    ["Name-NormalizedRealm"] = {
      lifetime = {
        casts = <n>,                    -- cast counter lives at the bucket root only
        zones = {
          [zoneName] = {                -- zoneName = localized GetRealZoneText()
            mapID = <uiMapID>,          -- raw GetBestMapForUnit at catch time (additive)
            subs = {
              [subZoneName] = {         -- subZoneName = localized GetSubZoneText()
                mapID = <uiMapID>,      -- raw GetBestMapForUnit at catch time (additive)
                items = {
                  [itemID] = { count = <n>, name = <string>, quality = <n>, link = <hyperlink> },
                },
              },
            },
          },
        },
      },
      session = { ... },              -- DISPOSABLE live-session snapshot (see below):
                                      -- casts/zones like lifetime, plus activeTime,
                                      -- lastCastEpoch, lastCastZone
    },
  },
}
```

- **Per-character data is persisted; the account-wide rollup is derived at display time**
  in the data layer, so the invariant *account total = sum of characters* can't be broken
  by a rendering path.
- **Lifetime** counts persist; **session** counts live in memory, linked by reference into
  the DB as a snapshot that survives `/reload` (and logout) until the session-end rules
  retire it — see the `session` bullet below.
- **`session` (per char, additive — no `DB_VERSION` bump):** the live session struct.
  Because it's the *same table* the in-memory store uses, it serializes at logout/reload
  with no explicit save step. Shape: `casts`/`zones` exactly like `lifetime`, plus
  `activeTime` (accumulated counted seconds), `lastCastEpoch` (`time()` at the last cast —
  the only timestamp that crosses a reload; the uptime-based `lastCastAt` lives only in
  memory and is dropped at restore), and `lastCastZone`. This is **disposable** data — the
  opposite policy from the catch history: restore sanitizes the shape, discards anything
  malformed, and applies the idle end-rule to the epoch gap; a future shape change may
  simply discard old snapshots, never migrate them. Other characters' stale snapshots are
  ignored (only the current character's is loaded into the live store), so the
  account-session rollup still sees exactly one live session.
- `name`/`quality`/`link` are stored with the first record of an item (and backfilled if an
  earlier record lacked them) so display never has to re-scan; if a name is still missing
  at render time, it is parsed from the stored `link`.
- **`mapID` (zone + sub buckets, additive — no `DB_VERSION` bump, no reader consumes it
  yet):** the raw `C_Map.GetBestMapForUnit("player")` at catch time — possibly a
  micro/floor map (caves and city districts have their own uiMapIDs), deliberately NOT
  normalized at write time. Never overwritten with nil (a loading-screen lookup failure
  must not erase a good id). It exists so a future migration can re-key zones
  **locale-safely**: re-key by parent-normalized mapID (walking `C_Map.GetMapInfo` up to a
  Zone-type map), derive zone display names live via `C_Map.GetMapInfo(mapID).name` (which
  returns the *current locale's* name), and fall back to a name scan for records that
  predate the field. Subzones stay keyed by localized string — subzones have no stable ID.
  Until that migration, zones remain keyed by localized `GetRealZoneText()` strings and
  every read seam is name-based (a deliberate decision: grouping reads by raw mapID would
  wrongly split zones whose subzones sit on different micro-maps).
- Character key: `UnitName("player") .. "-" .. GetNormalizedRealmName()`, resolved lazily
  at first use (PEW-safe; the normalized realm isn't reliable at `ADDON_LOADED`). Alt
  display names strip the realm; the DB key keeps it (so same-named alts across realms
  stay distinct in the data while merging in display, if desired).

## Versioning policy

`DB_VERSION` is checked at `ADDON_LOADED`. Unlike a rebuildable cache DB — where "bump
version → reset, carry settings over" is an acceptable migration strategy — **here the catch
history is real, non-reconstructible user data**: there is no way to re-derive how many fish
someone caught in a zone last month. So:

- A version bump must run a genuine `version == k → transform` migration that **preserves
  the catch history**, never wipes it.
- Additive changes (a new optional field, a new setting) don't bump the version: readers
  tolerate `nil` and `ns.InitSettings` default-fills/sanitizes the settings table (using
  `== nil` checks, never falsy, so a persisted `false` survives).
- **Downgrade guard:** if the stored `db.version` is *newer* than the build's `DB_VERSION`
  (a newer addon version wrote it, then the player rolled back), the addon leaves the
  persisted table **completely untouched** — zero writes, so it re-serializes as-is at
  logout — warns once in chat, and runs the session on a throwaway in-memory store:
  tracking works and settings are usable (at their defaults — the newer-schema saved
  settings are deliberately left unread), but nothing from that session persists. This
  prevents a rollback from silently re-saving (and corrupting) a schema it doesn't
  understand.
- `addonVersion` (the TOC version string, restamped every load) is a write-only
  diagnostic for bug-report SavedVariables; it never drives logic.

## WoW API notes (gotchas)

Facts about the current API surface (Midnight, 12.0.x). Most are the reason a given design
choice looks the way it does — the load-bearing assumptions the design rests on. Any still
awaiting in-game confirmation are flagged inline.

- **Fishing state detection.** *Implemented* via `UNIT_SPELLCAST_CHANNEL_START` /
  `UNIT_SPELLCAST_CHANNEL_STOP` (Fishing is a channel) filtered to `unit == "player"` and
  the Fishing spell. A real fishing cast fires **two** spells: **`131476`** (the one the player
  casts) which triggers **`131474`** (the channel) — confirmed in-game via two
  `UNIT_SPELLCAST_SUCCEEDED`. Detection matches **either id** *or* the shared **name** "Fishing"
  (so a pole-override variant still registers); the name comes from the single
  `ns.FishingSpellName()` resolver (tries `C_Spell.GetSpellName` on 7620 → 131474 → 131476,
  legacy `GetSpellInfo` as fallback, **memoizing only a successful lookup** — the
  non-localized "Fishing" literal is returned per-call and never cached, so an early nil
  lookup can't poison detection or the cast for the session; Casting.lua uses the same
  resolver). `CHANNEL_START` sets `ns.fishingActive`
  + `ns.lastFishing`, counts a cast, and fires the auto-open notifier. A pole-equipped check
  (`GetInventoryItemID("player", 16)`) remains an optional secondary signal. Confirm the
  spellID and that the channel events fire in-game.
- **Catch detection.** *Implemented.* One handler for **`LOOT_READY`** (fires *before* the
  loot window shows — the earliest addon-visible point; external fast-looters act here and
  can finish before `LOOT_OPENED` ever fires) and **`LOOT_OPENED`** (fallback), with a
  **once-per-window guard** cleared at `LOOT_CLOSED` and on the next fishing cast (backstop
  for a missed `LOOT_CLOSED`). The guard is set only when a window is actually processed —
  a gate failure leaves it clear so the fallback event gets its own chance. Gated to
  fishing by **`IsFishingLoot()`** OR the heuristic (`ns.fishingActive` or loot within ~1s
  of the last fishing channel), so mob/chest loot is never counted. The reader walks
  `GetNumLootItems` and reads each slot with `GetLootSlotLink` (nil for money → not
  tracked) + `GetLootSlotInfo` (name, quantity, quality); `GetItemInfoInstant(link)` gives
  the itemID (nil for currency → not tracked). All slots are recorded in one pass, then
  **one** `FireRefresh` repaints the UI. (`IsFishingLoot()` behavior on 12.0.x fishing
  loot awaits the in-game pass; the heuristic keeps working regardless.)
- **Catch *auto-loot*.** *Implemented.* The same handler, when the `autoLoot` setting is on
  **and the client isn't already native-auto-looting** (both loot events carry the client's
  `autoLoot` flag as their first payload — when it's set, the client is grabbing every slot
  itself and our pass would double-request), calls `LootSlot(i)` on every slot (items,
  money, and currency alike) — looping **in reverse** (`for i = n, 1, -1`) because looting
  a slot re-indexes the list, and reading each slot's info **before** looting it. No secure
  button: `LootSlot()` is callable from the insecure loot-event handler (the bobber click
  is the hardware event) — the standard insecure fast-loot pattern on current retail. No
  `ConfirmLootSlot` auto-confirm — fished loot isn't BoP, so the rare confirm dialog is
  left for the player. **Load-bearing in-game check:** confirm `LootSlot()` from the
  handler loots fully, taint-free, on 12.0.7. **Fallback if it's ever blocked:** toggle the
  `autoLootDefault` CVar on during the fishing window and restore it after.
- **The cast is a secure *binding* (by name), not a button.** *Implemented (no world overlay, no
  action button).* For the Fishing profession spell on 12.0, a secure button silently no-ops no
  matter how it's configured — `type="spell"` (→ `CastSpellByID(131474/131476)` and
  `CastSpellByName("Fishing")`) and `type="macro"` (→ `macrotext="/cast Fishing"`) **all failed
  in-game**, while a plain `/cast Fishing` macro works. So the cast goes through the **secure
  binding system, by name**: `SetOverrideBindingSpell(owner, true, key, <localized name>)`, which
  resolves the spell like `/cast`. The localized name comes from the shared
  `ns.FishingSpellName()` resolver in Core.lua (7620 → 131474 → 131476; success-only
  memoization — see *Fishing state detection*). Two override owners: a **persistent** one for the keybind (the player's "Cast
  Fishing" key, re-applied OOC) and a **transient** one for the double-click (`"BUTTON2"`, armed on
  the second of two quick right-downs, cleared by a short `C_Timer`). The double-click is detected
  via the **`GLOBAL_MOUSE_DOWN` event** — **not `WorldFrame:HookScript`, which taints the cast so it
  no-ops** even with a correct binding. All binding changes are `InCombatLockdown`-guarded and
  re-applied on `PLAYER_REGEN_ENABLED`. (**Bugs fixed across iterations:** world overlay broke
  hover/mouselook; first-click arming stuck character-rotate; per-click attribute changes tainted
  the cast; the spell APIs / macrotext don't cast this profession spell; the WorldFrame hook
  tainted the cast.)
- **Keybind category.** The cast binding gets its **own "Fish & Tips " top-level category** in Key
  Bindings via `category="Fish &amp; Tips "` in [Bindings.xml](Bindings.xml). A custom category
  that resolves to a global *token* taints; a plain-text value that doesn't — assured by the
  **trailing space** — is taint-safe. Don't drop the trailing space or
  use a token.
- **`Bindings.xml` is auto-loaded** by the client from the addon folder — **do NOT list it in the
  `.toc`.** If you do, the generic UI XML loader (which only knows the `<Ui>` frame schema) also
  parses it and warns "Unrecognized XML" for `<Binding>` / `name` / `category` (the binding still
  works via auto-load, so it's warnings-with-a-working-binding).
- **Cast mode + delay.** `castMode` (`off` default / `doubleclick` / `key` / `both`) selects the
  trigger path(s); `castDelay` (default 0.3s) is the double-click window. Both are account-wide
  settings (no `DB_VERSION` bump); the panel exposes a dropdown + slider.
- **Addon Compartment.** *Implemented — the default access path.* The TOC's
  `## AddonCompartmentFunc` / `...FuncOnEnter` / `...FuncOnLeave` directives name **global**
  functions (defined in UI.lua) that Blizzard resolves at load; registration is **static and
  always on** — there is no per-addon runtime toggle, the drawer appears once any installed
  addon registers an entry, and its visibility is a player-side Blizzard setting. The entry's
  icon comes from the existing `## IconTexture`. Since 11.0 the handlers receive
  `(addonName, buttonName)` with **no menu-button frame**, so the tooltip anchors defensively
  (a passed region if one arrives, else the global `AddonCompartmentFrame`, else skipped).
  Click mirrors the minimap button: left → toggle the window, right → options. Because the
  compartment covers reachability, the custom minimap button is **opt-in** (`showMinimap`
  default off — flipped for fresh installs only; `applyDefaults` fills `== nil`, so an
  existing user's stored `true` keeps their button). (Exact 12.0.x compartment behavior —
  arg shapes, right-click delivery, tooltip anchor — awaits the in-game pass.)
- **Zone resolution.** `GetRealZoneText()` / `GetSubZoneText()` for names, plus
  `C_Map.GetBestMapForUnit("player")` for a stable mapID — stamped on the zone and sub
  buckets at write time (see *DB schema*). **Log by the loot event, not by
  pool detection:** Midnight's Voidstorm "Oceanic Vortex" pools resist auto-detection but
  still produce loot, so tag the catch with whatever zone/subzone is readable rather than
  dropping it.
- **"Secret Values" (`C_Secrets`, new in 12.0)** restrict combat-sensitive unit data
  (health/power/cooldowns/auras) on tainted paths. They do **not** touch loot, containers,
  CVars, or zone APIs — so the data side of this addon is unaffected. (12.0.7 additionally
  made loot/money/rep/XP no longer secret.)
- **Auctionator integration (optional, external).** The price overlay calls Auctionator's
  documented **public** integration API: `Auctionator.API.v1.GetAuctionPriceByItemID(callerID,
  itemID)`, which returns the market price in **copper** (or `nil` when there's no scanned data
  for the item). `callerID` is just a non-empty string (we pass the addon name, `"FishTips"`) —
  no registration/handshake. `itemID` must be a **number** (the API `error()`s otherwise, so we
  `tonumber()` and `pcall` the call). Presence is detected by checking the API table exists at
  call time (`ns.PricingActive`), which is load-order-safe. The options checkbox is **not** grayed
  out when Auctionator is absent — the only Settings-API way to disable a control nests it under
  another (indented), so the checkbox stays top-level and is simply inert (`PricingActive` false →
  nothing renders), with the requirement stated in its tooltip. We consume only the published API; the
  signature/units come from its public documentation. (Not yet
  runtime-confirmed on 12.0.x.) Optional future hook: `RegisterForDBUpdate` to
  repaint after an AH scan; deferred (prices rarely change mid-fishing).
- **Fishing skill is awkward** (`GetProfessions` / `GetProfessionInfo`; the fishing journal
  panel API is effectively blocked, so other authors brute-force skill lookups). This is
  *why a skill display is deferred* for now.
- **Cast counting** for fish/hour comes from the `UNIT_SPELLCAST_*` events for the Fishing
  channel — pure data, unrestricted. *Implemented:* `ns.RecordCast()` fires on
  `UNIT_SPELLCAST_CHANNEL_START`.
- **Auto-open on fishing.** *Implemented.* `CHANNEL_START` fires `ns.FireFishingStart()`;
  the UI subscribes and calls `UI.ShowWindow(mode)` per the `autoOpen` setting — `"off"`
  (do nothing), `"full"` (the stats window), or `"collapsed"` (the compact strip). It only
  acts when nothing is already up (so it never fights a surface the player is using) and aligns
  the collapsed form to the chosen mode via `SetCollapsed`. It is transient — it never persists
  `uiShown`, so an auto-open can't overwrite the player's manual show/hide preference. Its
  symmetric half is **auto-hide** (`autoHide`, default on): when the session pauses, a surface
  that auto-open showed *and the player never touched* hides itself again — full mechanics and
  guards in *What it does* §5. `autoOpen` is an account-wide
  setting (no `DB_VERSION` bump); the panel exposes it as a dropdown, and the old boolean
  `autoOpenOnFishing` is migrated to it (`true`→`"full"`, `false`→`"off"`) at load.
- **Two clocks.** `GetTime()` is an uptime clock — it does not survive `/reload` — while
  `time()` is wall-clock epoch. The session model stamps both at every cast: live math runs
  on `GetTime`, and only `lastCastEpoch` crosses a reload (restore drops `lastCastAt`).
  Related: `C_Timer.After` has no cancel handle, so the session-pause timer "cancels" via a
  generation token the next cast bumps (an in-flight callback sees the stale token and
  no-ops).

## Deferred / roadmap

These plug in behind the existing seams without changing the UI layer:

- **Legacy data importer** (reading a prior catch-tracker's SavedVariables). Deliberately
  cut from the initial release — older trackers are largely unmaintained and their users have
  moved on; we differentiate on UX + the integrated auto-loot instead. Revisit if demand
  appears.
- **Junk auto-discard** — *researched, not built.* Two viable paths once wanted, both keyed on
  the quality the loot reader already records: (a) **skip-loot grays** — don't call `LootSlot()`
  on quality-0 slots during fishing ("throw it back"); fully automatic and in-flow, but an
  un-looted slot leaves the loot window open on the gray (an in-game UX check). (b) **auto-sell
  grays at a vendor** — on `MERCHANT_SHOW`, sell quality-0 items via
  `C_Container.UseContainerItem(bag, slot)` (the standard vendor auto-sell pattern, proven on 12.0.7; a
  separate vendor-time feature, subject to a sell-rate throttle). *Deleting* grays on catch is
  **not feasible** — `DeleteCursorItem` needs a per-item hardware event and is macro-protected,
  so it can't run from the loot handler.
- **Splash/bite detection** — *not possible* via a clean API; listed only to record that
  it was considered and rejected.
- **Fishing-skill display** — blocked-ish API (see gotchas); revisit if Blizzard exposes a
  journal/statistics API.
- Auto-best-lure (secure button, prompt-not-silent), one-click gear/outfit swap
  (`C_EquipmentSet`, out of combat), enhanced/forced sound while fishing, and rare-catch
  alerts. (Gold/AH value: the **session price overlay shipped** — see *What it does* §4;
  per-zone gold/hour and lifetime gold analytics remain future work on top of it.)
- **Session history** — auto-end (§5) discards a closed session once fishing resumes; only
  the one-line chat summary survives. A "recent sessions" view (per-session tally, where,
  when) would plug in behind the seams by retaining the last N closed session structs in
  the disposable snapshot slot — same disposable-data policy, no migration burden.
- **Customizable themes** — the UI already carries a theme engine (palettes + body layouts)
  scaffolded behind `ApplyTheme`, currently locked to one look with no user-facing chooser.
  Exposing theme selection (and/or per-element color options) plugs in here without touching
  the data layer.
