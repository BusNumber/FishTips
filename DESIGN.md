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
> (gated to fishing, keyed by itemID), **auto-opening the window when fishing starts**,
> **fishing-only auto-loot** — the loot reader now calls `LootSlot()` to grab the catch (gated
> by the `autoLoot` setting, default on) — and an **Auctionator price overlay** (session gold
> values, on by default but only rendering when Auctionator is installed). Still roadmap: **junk
> auto-discard** (auto-selling or throwing back gray catches — see Deferred/roadmap).

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
giving a fish/hour rate. A movable stats window — toggled by a slash command and a minimap
button — shows the breakdown, with the current zone/subzone highlighted.

Display decisions (presentation only — they don't change the data): the window has a
**Session / Lifetime** toggle, and the **character / Warband scope selector appears only in
the Lifetime view** — a session is inherently the current character, so there is nothing to
scope. The converse control, a **"New session" reset button, appears only in the Session
view** (it pops a `StaticPopup` confirmation — guarding against an accidental wipe — that on
accept calls `ns.ResetSession`). Each catch row shows the **rarity-colored item name**
(poor-quality junk is dimmed well below the normal-item text so it visibly recedes), a thin
**frequency bar**, the **count**, and the count's **share %** of that location's catches. A
**location header** names the current zone/subzone (catch counts are carried by the
per-location list and the **footer stat bar** — `casts · catches · /hr · minutes` — so the
header itself stays uncluttered).

The **`includeJunk`** account-wide setting (default on) decides whether gray (quality-0)
catches appear at all. With it off, junk is dropped from the list **and** every total (the
footer counts, the rate, the top-zones chart) — but it is still **recorded**, so toggling it
back on restores the history. The filter is **display-time only**: it lives in the read seams
(below), nothing in the write-path or DB schema changes, and so it does **not** bump
`DB_VERSION` (additive boolean, `== nil` default-filled, sanitized to a boolean). Junk is just
`quality == 0` (already stored per catch); items with no recorded quality count as non-junk.

### 3. Fishing-only auto-loot — the *same* mechanism as tracking
This is the key design insight. When a loot window opens **during fishing**, Fish & Tips
reads every slot (recording each catch into the tracker) and then loots all of it — one
`LOOT_OPENED` handler walking the slots **in reverse** (looting re-indexes the list) and
calling `LootSlot()` on each. Because **we are the one doing the looting, the recorded counts
are exact** — this sidesteps a classic catch-tracker bug, where a separate "fast loot" addon
grabbed the fish before it could be counted. Non-fishing loot (mobs, chests, herbs) is never
touched: auto-loot is gated to a short window after a successful Fishing cast.

Auto-loot is gated by the **`autoLoot` setting** (default on), read live on each catch.
Tracking does not *require* it — with `autoLoot` off, Fish & Tips still reads the loot slots
at `LOOT_OPENED` to record the catch (best-effort, accepting that an external fast-loot addon
may win the race in that mode).

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

## Architecture

```
### FishTips.toc
Manifest. `## Title: Fish & Tips`, `## SavedVariables: FishTipsDB`.
Loads Core.lua, Casting.lua, UI.lua, Settings.lua (order matters).

### Core.lua
Data layer: SavedVariables DB + fishing-state detection + loot read/auto-loot +
zone resolution + the catch store + account rollup. Owns the `ns.Get*` seams.

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
**compact minimized strip**, a custom minimap
button, and a small **theme engine** — a registry of palettes + body layouts applied by
`ApplyTheme`. The theme engine is currently **locked to a single look** (no chooser is
exposed) but kept in code for future customizable themes. Reads only via `ns.*` seams.

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
- `ns.GetSessionScope()` → the scope that owns the live session (the current character)

The catch-counting seams (`GetTotals`, `GetZoneTotals`, `GetLocationItems`) apply the
`includeJunk` display filter here, in one place: `sumItems` (shared by the totals and zone
rollups) and `GetLocationItems` skip quality-0 items when `includeJunk` is off, so the list
and every total stay consistent. Filtering lives in the data layer, not the UI.

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
- `ns.RecordCatch(itemID, count, name, quality, link)` — record one fished item, keyed by
  itemID, tagged with the current real zone/subzone, into both lifetime and session.
- `ns.ResetSession()` — drop the current character's in-memory session store and restart the
  elapsed clock (the Session "New session" button). The persisted lifetime history is never
  touched; fires a refresh.
- `ns.RegisterFishingStart(fn)` / `ns.FireFishingStart()` — a notifier (parallel to
  `RegisterRefresh`/`FireRefresh`) the UI subscribes to so it can **auto-open** the window
  when fishing begins. `FireRefresh` only repaints an already-open window; this can show it.

The loot reader does both jobs from one `LOOT_OPENED` handler (gated to fishing): it reads
each item slot and calls `ns.RecordCatch`, and — when the `autoLoot` setting is on — calls
`LootSlot()` to grab the catch. It walks the slots **in reverse** and reads each slot's info
**before** looting it (a looted slot re-indexes the list and clears its link/info).

## DB schema

```
FishTipsDB = {
  version = 1,
  addonVersion = "<TOC version string>",        -- write-only diagnostic, never read
  settings = { ... },                           -- account-wide: behavior + display
  chars = {
    ["Name-NormalizedRealm"] = {
      lifetime = {
        casts = <n>,
        zones = {
          [zoneName] = {
            subs = {
              [subZoneName] = {
                casts = <n>,
                items = { [itemID] = { count = <n>, link = <hyperlink> } },
              },
            },
          },
        },
      },
    },
  },
}
```

- **Per-character data is persisted; the account-wide rollup is derived at display time**
  in the data layer, so the invariant *account total = sum of characters* can't be broken
  by a rendering path.
- **Lifetime** counts persist; **session** counts live in memory only and reset on
  login/`/reload`.
- A representative `link` is stored per item so the name/quality icon can be resolved
  lazily at display time without re-scanning.
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
  (so a pole-override variant still registers); the name is resolved via
  `C_Spell.GetSpellInfo(131476)`. `CHANNEL_START` sets `ns.fishingActive`
  + `ns.lastFishing`, counts a cast, and fires the auto-open notifier. A pole-equipped check
  (`GetInventoryItemID("player", 16)`) remains an optional secondary signal. Confirm the
  spellID and that the channel events fire in-game.
- **Catch detection.** *Implemented.* On `LOOT_OPENED`, gated to fishing (`ns.fishingActive`
  or a catch within ~1s of the last fishing channel, so mob/chest loot is never counted), the
  reader walks `GetNumLootItems` and reads each slot with `GetLootSlotLink` (nil for
  money/currency → not tracked) + `GetLootSlotInfo` (name, quantity, quality);
  `GetItemInfoInstant(link)` gives the itemID. Each item is sent to `ns.RecordCatch`.
- **Catch *auto-loot*.** *Implemented.* The same `LOOT_OPENED` handler, when the `autoLoot`
  setting is on, calls `LootSlot(i)` on every slot (items, money, and currency alike) — looping
  **in reverse** (`for i = n, 1, -1`) because looting a slot re-indexes the list, and reading
  each slot's info **before** looting it. No secure button: `LootSlot()` is callable from the
  insecure handler (the bobber click is the hardware event) — the standard insecure-`LOOT_OPENED`
  fast-loot pattern on current retail. No `ConfirmLootSlot` auto-confirm
  — fished loot isn't BoP, so the rare confirm dialog is left for the player. **Load-bearing
  in-game check:** confirm `LootSlot()` from the handler loots fully, taint-free, on 12.0.7.
  **Fallback if it's ever blocked:** toggle the `autoLootDefault` CVar on during the fishing
  window and restore it after.
- **The cast is a secure *binding* (by name), not a button.** *Implemented (no world overlay, no
  action button).* For the Fishing profession spell on 12.0, a secure button silently no-ops no
  matter how it's configured — `type="spell"` (→ `CastSpellByID(131474/131476)` and
  `CastSpellByName("Fishing")`) and `type="macro"` (→ `macrotext="/cast Fishing"`) **all failed
  in-game**, while a plain `/cast Fishing` macro works. So the cast goes through the **secure
  binding system, by name**: `SetOverrideBindingSpell(owner, true, key, <localized name>)`, which
  resolves the spell like `/cast`. The localized name comes from `C_Spell.GetSpellName(7620)` (→
  131474 fallback). Two override owners: a **persistent** one for the keybind (the player's "Cast
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
- **Zone resolution.** `GetRealZoneText()` / `GetSubZoneText()` for names, plus
  `C_Map.GetBestMapForUnit("player")` for a stable mapID. **Log by the loot event, not by
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
  `uiShown`, so an auto-open can't overwrite the player's manual show/hide preference, and there
  is no auto-close (the surface stays until the player closes it). `autoOpen` is an account-wide
  setting (no `DB_VERSION` bump); the panel exposes it as a dropdown, and the old boolean
  `autoOpenOnFishing` is migrated to it (`true`→`"full"`, `false`→`"off"`) at load.

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
- **Customizable themes** — the UI already carries a theme engine (palettes + body layouts)
  scaffolded behind `ApplyTheme`, currently locked to one look with no user-facing chooser.
  Exposing theme selection (and/or per-element color options) plugs in here without touching
  the data layer.
