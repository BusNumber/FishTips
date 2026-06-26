# Fish & Tips

A lightweight World of Warcraft fishing addon: **double-right-click to cast**, **auto-loot
your catch**, and **track every fish by zone and subzone** — session and lifetime, across
all your characters. With **Auctionator** installed, it also shows what your session's catch
is worth at auction, live, while you fish.

## What it does

- **Cast Fishing your way.** A keybind, the classic **double-right-click** click-the-water
  cast, both, or off — your choice in the options. (Off by default; pick a mode to enable it.)
- **Fishing-only auto-loot.** You click the bobber; when the loot window opens *while
  fishing*, Fish & Tips loots the whole thing for you. Looting a mob or chest is left
  alone. Because the addon does the looting, your catch counts are **exact** — no fish
  slips past the counter (a long-standing annoyance with older trackers). On by
  default; toggle it in options or with `/ft autoloot off`.
- **Per-location catch tracking.** Every catch is logged by **zone + subzone**, with
  **current-session** and **lifetime** totals, **per character** plus an account-wide
  rollup — and a casts/catch-per-hour readout. Gray junk catches can be hidden from the
  stats with one toggle (shown by default — `/ft junk off` or the **Include junk items**
  option); they keep being tracked either way.
- **Auctionator gold values.** Fish to sell? If you have **Auctionator** installed, the stats
  window shows what your session is worth: each fish shows the value of your catch (count ×
  auction price), and the footer and compact strip show a running **session total**. On by
  default (it only ever shows with Auctionator installed); turn it off under **Show Auctionator
  prices** or with `/ft auc off`.

The stats live in a movable window you can toggle from a slash command or the minimap
button — and it can **open itself when you start fishing** — with your current spot
highlighted:

```
Fish & Tips — this session                  78 casts · 284 catches/hr
  Voidstorm — Oceanic Vortex   [special pool]
    Voidscale Eel ............ 23 (32%)
    Abyssal Pike ............. 18 (25%)
    Stormfin Darter .......... 15 (21%)
  78 casts  ·  23 catches  ·  284/hr  ·  15m
```

## Installation

**Manual:**

1. Download/clone this addon.
2. Copy the folder into your AddOns directory so it sits at:
  - **Windows:** `World of Warcraft\_retail_\Interface\AddOns\FishTips\`
  - **macOS:** `World of Warcraft/_retail_/Interface/AddOns/FishTips/`
3. The folder name must be **`FishTips`** (it has to match `FishTips.toc`).
4. Restart WoW, or `/reload` if it's running. Make sure **Fish & Tips** is enabled in the
   AddOns list on the character-select screen.

Options and the stats window are reachable from the slash command and a minimap button.

## Scope (current version)

The core loop runs end to end: open the window with `/ft` or the minimap button, switch
between Session and Lifetime and between a character and your Warband, double-right-click the
water to cast, and watch your catches auto-loot and log by location.

- 🟢 Stats window (per zone/subzone · session + lifetime · per character + Warband) — *built and populated by live tracking*
- 🟢 Catch tracking (recording fish by zone, keyed by item ID) — *working*
- 🟢 Cast count and fish/hour — *working*
- 🟢 Auto-open when fishing starts (full window or compact strip) — *working*
- 🟢 Casting — keybind **and/or** double-right-click, chosen in options (off by default) — *working*
- 🟢 Fishing-only auto-loot (on by default; toggle in options) — *working*
- 🟢 Auctionator gold values for the session (on by default; shows only with Auctionator installed) — *working*
- ⬜ Auto-discard junk (sell or throw back gray catches) *(planned)*
- ⬜ Import from legacy catch-trackers *(not planned)*
- ⬜ Auto-best-lure, gear/outfit swap, enhanced sound *(planned)*
- ⬜ Gold / auction-house analytics per zone *(planned)*

## Safety

Fish & Tips does nothing automatic that you didn't trigger. The cast happens on **your**
keypress or double-click — through Blizzard's standard secure mechanism — and the loot only
happens because **you** clicked the bobber:
there's no loot window without your click, and the addon simply grabs what that window
offered. So there's no automation, no "AFK fishing," and nothing against the Terms of
Service. The addon cannot and does not detect the bobber splash; you fish, it keeps the books.

## Contributing

Bug reports and PRs are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for the dev
setup and the in-game test checklist, and [DESIGN.md](DESIGN.md) for how and why it works.
One hard rule: all code must be original work, written from public API documentation.

## Support

Fish & Tips is free and always will be. If it lands you a few more fish, you can
[buy me a coffee](https://buymeacoffee.com/busnumber). ☕

## License

Copyright © 2026 BusNumber.

Licensed under the [GNU General Public License v3.0](LICENSE).

---

World of Warcraft and Blizzard Entertainment are trademarks or registered trademarks of
Blizzard Entertainment, Inc. This addon is unofficial and is not affiliated with or
endorsed by Blizzard Entertainment.
