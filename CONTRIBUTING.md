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

### Sessions

- [ ] With **Start a new session = After inactivity** (the default): a cast within the
      timeout continues the session; a cast after a break longer than the timeout starts a
      fresh one, with **one** chat line summarizing the old session's tally (no line when it
      had no catches; no line from the manual **New session** button).
- [ ] **When the zone changes**: casting in a new zone starts a fresh session; recasting in
      the same zone never does. **Zone change + inactivity**: needs BOTH — an AFK return to
      the same spot continues, and a quick hop to the next zone's pool continues too.
- [ ] **Manually only**: nothing but the **New session** button ever resets the session —
      not zone changes, not hour-long breaks, not `/reload`.
- [ ] The **Session view lists the whole session across zones**: fly to another zone and
      keep fishing — earlier catches stay in the list (merged per fish); the **Lifetime**
      view still filters to the current zone/subzone.
- [ ] With **Pause session when not fishing** on (the default), the footer minutes stop climbing
      ~grace after the last cast and fish/hr stops decaying; the next cast resumes with no
      jump in the minutes. With it off, the timer runs wall-clock. Flying a couple of
      minutes between pools counts toward the timer either way.
- [ ] Mid-fishing `/reload` → the session (counts, catches, timer) **resumes**, with no
      jump or dip in the footer minutes; after a break longer than the inactivity timeout,
      login starts clean instead.
- [ ] **Auto-hide:** a window (or compact strip) that **auto-open** showed tucks itself away
      ~grace after the last cast, and comes back on the next cast. A window opened via the
      slash command or minimap button is **never** auto-hidden; neither is an auto-opened one
      the player has since dragged or clicked (mode/scope/New-session), nor one currently
      under the mouse. Turning the **Auto-hide stats window** checkbox off disables all of
      it — as does turning off **Pause session when not fishing** (auto-hide is part of the
      pause feature; both nested controls gray out with it).
- [ ] **Close beats auto-open:** with auto-open on, close the stats window mid-fishing
      (the X, `/ft`, or a compartment/minimap left-click) → the next casts do **not**
      re-open it, and one chat line explains why — only the first such close per login
      prints it. After a real break (~the pause grace since your last cast) the next cast
      auto-opens again — **including** with **Start a new session = Manually only** and
      **Pause session when not fishing** unchecked — and reopening manually right after
      closing also re-arms auto-open on its own.
- [ ] **Close while idle never suppresses:** closing the window in town (or any time
      longer than the grace after your last cast) prints no hint, and the next cast still
      auto-opens. Collapsing to the compact strip (the `_` button) never suppresses either —
      the strip is still up — and an auto-hidden window still comes back on the next cast
      (auto-hide is not a close).
- [ ] **Compact parity:** with **Auto-open = Collapsed view**, closing the strip
      mid-fishing suppresses the same way (next casts don't re-show it) and the next
      fishing break re-arms it. With **Auto-open = Disabled**, a mid-fishing close prints
      no hint.

### Persistence & scope

- [ ] Catch fish, `/reload` → lifetime totals survive; the session resumes (see *Sessions*
      above for the boundary rules).
- [ ] Catch on two characters → each character's data is separate, and the **account
      rollup equals their sum**.
- [ ] Same-named characters on different realms stay distinct in the data.

### UI

- [ ] The stats window toggles via the slash command **and** the addon-compartment entry
      (the fishing-pole icon in the minimap's addon drawer): left-click toggles the window,
      right-click opens options, and hovering the entry shows the tooltip with both hints.
- [ ] On a fresh install the custom minimap button is **hidden**; enabling **Show minimap
      button** shows it live. With it enabled, the button sits on the minimap ring — also
      on an Edit-Mode-resized/rescaled minimap (and repositions when the minimap is resized
      live) — toggles the window on left-click, opens options on right-click, and drags
      around the ring. An existing SavedVariables with `showMinimap = true` keeps the
      button after upgrading.
- [ ] It drags and remembers its position across `/reload`.
- [ ] The current zone/subzone is highlighted; session vs lifetime are both correct.
- [ ] The Session view's **New session** button pops a confirmation dialog; **Yes** resets the
      session counts and the timer (fish/hr too) with the Lifetime totals untouched, while **No**
      or Esc leaves the session intact.
- [ ] **Catch rows are real item rows:** hovering a row shows the item tooltip (also for a
      demo/legacy row with no stored link — by-ID fallback, no Lua error); shift-click with
      an open chat box inserts the item link (a link-less row silently does nothing); each
      row shows its item icon, with gray-quality icons dimmed like their names.
- [ ] **Wheel scrolling:** with more than 6 fish types, the mouse wheel scrolls the list —
      including while the cursor is over a row — and the window height never changes; with
      6 or fewer it does nothing. The **+N more** line pages down on click and flips to
      **Back to top** at the end; the scroll position survives new catches landing, and
      switching view/scope/zone resets it.
- [ ] **Dragging from a catch row still moves the window**, and a catch landing while a row
      is hovered doesn't wedge the tooltip or the hover highlight.
- [ ] **Auto-hide interplay:** an auto-opened window is not auto-hidden while the mouse is
      over a row, and a row click or wheel scroll promotes it to player-owned (it stays up
      after the pause).

### Options panel

- [ ] Options → AddOns → **Fish & Tips** renders with the modern controls (dropdown, slider,
      checkboxes) and the donate/version footer.
- [ ] Changing **Auto-cast** / **Show minimap button** takes effect immediately; the
      double-click delay slider is disabled unless a double-click cast mode is selected.
- [ ] The **Sessions** block renders: the **Inactivity timeout** slider is disabled unless
      an inactivity-based mode is selected in **Start a new session**; **Pause after** and
      **Auto-hide stats window** are nested under **Pause session when not fishing** and
      both gray out when it's unchecked. `/ft session manual|idle|zone|zoneidle` switches
      the mode.
- [ ] **Auto-open when fishing** = Full window / Collapsed view / Disabled does the right thing
      on the next cast (and only when the window isn't already up).
- [ ] Unchecking **Include junk items** (or `/ft junk off`) hides gray catches from the list
      **and** the totals/zone chart immediately (no `/reload`); re-checking shows them again.
      A gray catch is still tracked while hidden (visible again when re-enabled), and the count
      stays correct.
- [ ] Unchecking **Show item icons** (or `/ft icons off`) removes the icons immediately and
      the rows return to the exact pre-icon layout (full-width name and bar); re-checking
      restores them. Tooltips and shift-click linking work either way.
- [ ] The native **Defaults** button resets every option (minimap button hides, cast mode
      reverts, auto-open returns to Full window, junk items shown, item icons shown,
      Auctionator prices on, sessions back to After inactivity / 30m / pause on / 5m /
      auto-hide on).

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
