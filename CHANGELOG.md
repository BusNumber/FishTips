# Changelog

All notable changes to Fish & Tips are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-07-10

### Added

- **Version-rollback safeguard** — if your saved data was written by a newer version of the
  addon, Fish & Tips now warns and runs the session without saving instead of risking your
  catch history.
- Each catch location now also records its **map ID** alongside the zone name, laying the
  groundwork for keeping your history intact across game-language changes.

### Changed

- **Catches are now recorded the moment loot becomes available** (before the loot window
  even shows), with a once-per-window guard — so counts stay exact alongside fast-loot
  addons and across loot-window quirks. When the game's own auto-loot is doing the
  looting, Fish & Tips records without double-requesting the loot. Fishing loot is now
  identified by the game's own check first, with the timing heuristic as fallback.
- **The stats window no longer rebuilds itself from scratch on every update.** It now
  reuses its widgets, repaints at most once per frame, and skips repainting surfaces that
  aren't visible — long fishing sessions no longer accumulate UI memory.

### Fixed

- The compact strip showed zeros when the Lifetime scope selector pointed away from the
  current character — it now always shows the live session.
- On non-English game clients, an unlucky early spell lookup could leave the addon stuck
  with the English spell name "Fishing" — weakening fishing detection for the rest of the
  session, and leaving the cast mis-bound until it re-applied. Casting and detection now
  share one resolver that keeps retrying until a real lookup succeeds.

## [1.0.0] - 2026-06-26

Initial public release. For **Midnight, patch 12.0.7** (retail).

### Added

- **Per-location catch tracking** — every fish logged by zone + subzone, with current-session
  and lifetime totals, per character plus an account-wide (Warband) rollup.
- **Fishing-only auto-loot** — when a loot window opens while fishing, Fish & Tips loots the
  whole catch for you; mob and chest loot is left untouched. Because the addon does the looting,
  the recorded counts stay exact. Toggle in options or with `/ft autoloot on|off`.
- **Cast Fishing** by keybind, the classic **double-right-click** click-the-water cast, both, or
  off (the default) — chosen in options or with `/ft cast off|doubleclick|key|both`, with an
  adjustable double-click delay.
- **Auto-open** the stats window (full or compact) when fishing starts.
- **Optional Auctionator price overlay** — with Auctionator installed, the Session view shows
  each catch's auction value and a running session total. Toggle with `/ft auc on|off`.
- **Hide gray junk** from the stats and totals — the **Include junk items** option 
  or `/ft junk on|off`.
- **Movable stats window** with a Session/Lifetime toggle and a character/Warband scope selector,
  and a **compact strip**.

[1.0.0]: https://github.com/BusNumber/FishTips/releases/tag/v1.0.0
