# Contributing

Thanks for your interest! Fish & Tips is deliberately small, with a strict
data/presentation split and a handful of design invariants. Please read
[DESIGN.md](DESIGN.md) before changing behavior — it documents *why* the addon works the
way it does, and several "obvious simplifications" are addressed there (the no-bobber-event
reality, the loot-window-drives-tracking insight, the migrate-don't-reset DB rule).

## Originality policy (hard rule)

All contributions must be **original work**, written from public API documentation —
[warcraft.wiki.gg](https://warcraft.wiki.gg), official Blizzard developer docs, or
Blizzard's own UI source for verifying that an API exists.

Every contribution must be written from scratch against those public references: unvetted
copying puts this project's GPLv3 licensing at risk, so PRs that don't appear to be original
work will be declined.

## Dev setup

1. Clone the repo anywhere and symlink it into your AddOns directory:

   ```
   …/World of Warcraft/_retail_/Interface/AddOns/FishTips → <your clone>
   ```

   The folder (or symlink) name must be exactly **`FishTips`** — it has to match the
   `.toc` base name. (The in-game display name is "Fish & Tips"; `&` isn't a valid folder
   character, so the folder/slug drops it.)
2. Enable Lua error display in-game: `/console scriptErrors 1`.
3. After editing files, `/reload` picks up the changes.
4. To work on the stats UI without fishing, `/ft demo on` fills the window with a sample
   dataset (`/ft demo off` clears it). This is a **dev-only** affordance — it is not
   advertised to users and never writes to the catch history. The sample catches are keyed
   by **real Midnight fishing itemIDs** (Lynxfish, Arcane Wyrmfish, Sin'dorei Swarmer,
   Shimmersiren, Tender Lumifin, Eversong Trout), so with Auctionator installed the price
   overlay shows live AH prices in demo mode too.
5. To debug casting, `/ft castdebug` prints the live cast state (mode, the resolved Fishing
   spell name, and the assigned keybind key) and, while on, logs when the double-click arms
   the cast — so you can tell a trigger-not-firing from a cast-not-casting. Also **dev-only**.

Code conventions: the Lua files share the private addon table via the
`local addonName, ns = ...` vararg. Keep the data/presentation split — new data sources
and game-state logic go in `Core.lua` behind the `ns.Get*` seams; `UI.lua` reads only
through those seams. Secure-frame code stays isolated in `Casting.lua` to contain taint.
User-facing strings go through **`ns.L["..."]`** (defined in `Locale.lua`, first in the
TOC) — the English string is the key, and format strings are wrapped whole
(`ns.L["+%d more"]`) so translations can reorder words. Slash tokens, dev-only output,
texture paths, and the "Fish & Tips" brand stay as plain literals.

## Static checks & automated tests

WoW globals (`C_Container`, `Enum`, `C_Map`, `SecureActionButtonTemplate`, …) don't exist
outside the game, so local checks are syntax, lint, and the stubbed data-layer tests:

- `luac -p <file>` — syntax-only compile pass (or `luajit -bl <file> /dev/null`;
  LuaJIT speaks Lua 5.1, the same dialect as WoW, while modern `luac` is 5.4).
- `luacheck .` — uses the repo's `.luacheckrc` (which knows the WoW globals).
- `luajit tests/run_tests.lua` — runs the data-layer test suite.

### Automated tests (`tests/`)

The suite loads the **real** `Locale.lua` + `Core.lua` + `Settings.lua` against minimal
WoW API stubs (`tests/wow_stubs.lua` — a mock event frame, a loot-window model, clock,
zone/identity/spell knobs) and drives actual game events (`ADDON_LOADED`, the fishing
channel events, `LOOT_READY`/`LOOT_OPENED`/`LOOT_CLOSED`) through the addon's own
handlers. It asserts the design invariants: account rollup = Σ characters, cross-realm
same-name characters stay distinct, the junk filter is consistent across every seam, each
loot window is recorded exactly once (with one UI refresh), the fishing gate, mapID
stamping, and the version-downgrade guard.

`UI.lua` and `Casting.lua` are deliberately **not** loaded — rendering and secure-binding
behavior can't be meaningfully stubbed; those claims belong on the in-game checklist
below. When adding data-layer behavior, add a test; when a claim needs the real client,
add a checklist item instead. CI (GitHub Actions) runs luacheck, a syntax pass over every
Lua file, and this suite on each push/PR.

## In-game verification

The addon can only be truly verified in-game. Before submitting changes, run through the
checks relevant to what you touched.

### Casting

The cast trigger is chosen with the **Auto-cast** dropdown in options (`off` default /
`doubleclick` / `key` / `both`), or `/ft cast off|doubleclick|key|both`.

- [ ] **off** (default): hover outline, camera mouselook, character rotate, move, and
      right-click interact all behave exactly as without the addon (no bindings touched).
- [ ] **key** / **both**: assign a key under Key Bindings → **Fish & Tips → Cast Fishing**; the
      key casts your fishing line. Hover/mouselook unaffected.
- [ ] **doubleclick** / **both**: double right-click over water casts; a single right-click
      still interacts/mouselooks and the hover outline still shows; tune the delay slider.
- [ ] No "action blocked" / taint errors, in or out of combat, including after `/reload`;
      switching the dropdown in combat doesn't error.

### Auto-loot + tracking (the core feature)

- [ ] Click a fished bobber → the loot window auto-loots fully, and every item is recorded
      under the **correct zone + subzone** — exactly once (no double-count across
      consecutive catches; the once-per-window guard resets between windows).
- [ ] Killing a mob / opening a chest does **not** trigger the fishing auto-loot — including
      loot opened moments after a fishing channel ends (`IsFishingLoot()` + heuristic gate).
- [ ] Counts stay **exact** even with a separate fast-loot/auto-loot addon enabled — no
      double-count, no missed catches.
- [ ] With the game's **native auto-loot** on (the Blizzard setting/CVar), a catch is
      recorded exactly once and looted exactly once (Fish & Tips records but leaves the
      looting to the client — no double-loot requests or errors).
- [ ] With auto-loot turned off in settings, catches are still tracked, and nothing is looted
      by the addon.
- [ ] If the CVar fallback is in use, the player's prior `autoLootDefault` is restored
      after fishing across `/reload`, logout, and a disconnect.

### Persistence & scope

- [ ] Catch fish, `/reload` → lifetime totals survive; the session view resets.
- [ ] Catch on two characters → each character's data is separate, and the **account
      rollup equals their sum**.
- [ ] Same-named characters on different realms stay distinct in the data.

### UI

- [ ] The stats window toggles via the slash command **and** the minimap button.
- [ ] It drags and remembers its position across `/reload`.
- [ ] The current zone/subzone is highlighted; session vs lifetime are both correct.
- [ ] The Session view's **New session** button pops a confirmation dialog; **Yes** resets the
      session counts and the timer (fish/hr too) with the Lifetime totals untouched, while **No**
      or Esc leaves the session intact.

### Options panel

- [ ] Options → AddOns → **Fish & Tips** renders with the modern controls (dropdown, slider,
      checkboxes) and the donate/version footer.
- [ ] Changing **Auto-cast** / **Show minimap button** takes effect immediately; the
      double-click delay slider is disabled unless a double-click cast mode is selected.
- [ ] **Auto-open when fishing** = Full window / Collapsed view / Disabled does the right thing
      on the next cast (and only when the window isn't already up).
- [ ] Unchecking **Include junk items** (or `/ft junk off`) hides gray catches from the list
      **and** the totals/zone chart immediately (no `/reload`); re-checking shows them again.
      A gray catch is still tracked while hidden (visible again when re-enabled), and the count
      stays correct.
- [ ] The native **Defaults** button resets every option (minimap shows, cast mode reverts,
      auto-open returns to Full window, junk items shown, Auctionator prices on).

### Auctionator price overlay (on by default)

- [ ] **Without Auctionator installed:** the **Show Auctionator prices** checkbox is a normal
      top-level control (not indented) and on by default; with no Auctionator it renders no prices
      and produces **no** Lua errors — it's simply inert.
- [ ] **With Auctionator installed + AH data, Session view:** with the option on (the default),
      each fish shows `(count × price 🪙)` floored to gold (number first, gold icon trailing); an
      item Auctionator has no data for shows `(? 🪙)`. The footer stat bar and the compact strip show
      a right-aligned `session total 🪙` (≈ the sum of priced catches across all zones this session).
      Toggling it
      off (the box or `/ft auc off`) clears all of it immediately (no `/reload`); back on restores it.
- [ ] **Session-only:** switching to **Lifetime** view hides the per-fish prices; switching
      back to **Session** restores them.
- [ ] With **Include junk items** off, a gray fish's value drops out of the session total too
      (the total stays consistent with the visible list).
