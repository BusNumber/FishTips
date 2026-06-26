# Changelog

All notable changes to Fish & Tips are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
