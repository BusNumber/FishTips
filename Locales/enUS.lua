local _, ns = ...

-- The string table: every piece of text this addon displays, keyed symbolically. This
-- file is the base locale -- it defines every key and is what any client without a
-- translation shows. A translation is a sibling file whose first line names its own
-- client language, ns.NewLocale("xxXX"), and which assigns the keys it covers; whatever
-- it leaves out stays English. (CONTRIBUTING.md has the step-by-step, DESIGN.md the
-- reasoning.)
--
-- Rules for values:
--   * Keep every placeholder (%s, %d, %.2f). To reorder them, use the game's positional
--     form (%1$s, %2$d) -- the numbers refer to the English order.
--   * A value is one string on one line; non-ASCII text is plain UTF-8 (no BOM).
--   * Where a count needs more than a singular/plural pair, the game's own plural escape
--     works inside a value: "%d |4cast:casts;".
--
-- Deliberately NOT here (see DESIGN.md): the "Fish & Tips" name, the /ft command, its
-- sub-command words and their usage lines, item and zone names (the game's own text),
-- and the punctuation that glues segments together.
local L = ns.NewLocale("enUS")

-- ---------------------------------------------------------------------------
-- Numbers and counted nouns

-- The character between groups of three digits (1,234,567).
L["THOUSANDS_SEPARATOR"] = ","

-- A count with its noun. _ONE is used for exactly 1, _MANY for every other count.
L["CASTS_ONE"]    = "%d cast"
L["CASTS_MANY"]   = "%d casts"
L["CATCHES_ONE"]  = "%d catch"
L["CATCHES_MANY"] = "%d catches"

-- ---------------------------------------------------------------------------
-- Stats window

L["MODE_SESSION"]    = "Session"      -- the two view buttons
L["MODE_LIFETIME"]   = "Lifetime"
L["BTN_NEW_SESSION"] = "New session"  -- resets the session; asks first (the popup below)
L["POPUP_NEW_SESSION"] = "Start a new session? This clears the current session's catches and timer. Your lifetime history is kept."

L["SCOPE_WARBAND"] = "Warband" -- the all-characters entry in the Lifetime view's character list

L["BADGE_SPECIAL_POOL"] = "Special pool" -- small tag beside the location name

-- The catch list: its heading in each view, the empty state, and the paging line under
-- a list longer than the window (%d is how many more rows there are).
L["LIST_TITLE_SESSION"]  = "Catches (this session)"
L["LIST_TITLE_LIFETIME"] = "Catches (lifetime)"
L["LIST_EMPTY"]          = "No catches here yet."
L["LIST_MORE"]           = "+%d more"
L["LIST_BACK_TO_TOP"]    = "Back to top"
L["TAG_NEW"]             = "New!" -- marks a fish caught for the first time ever; keep it short

L["ZONES_TITLE"] = "Top zones" -- Lifetime view's chart of the zones with the most catches
L["ZONES_EMPTY"] = "No zones tracked yet."

-- Footer stat line (Session view): casts, catches, catches per hour, minutes fished.
-- The first two %s are the counted nouns above ("12 casts", "5 catches").
L["STATLINE_SESSION"] = "%s    %s    %s/hr    %dm"
-- The compact strip: where you are, catches, catches per hour.
L["STATLINE_COMPACT"] = "%s    %s    %s/hr"
-- Session gold value with its hourly rate, "1,234 (4,936/hr)". Each %s is an amount
-- that already carries its gold icon.
L["VALUE_WITH_RATE"]  = "%s  (%s/hr)"

-- Labels under the three big numbers of the alternate window layout.
L["STAT_CATCHES"] = "catches"
L["STAT_CASTS"]   = "casts"
L["STAT_RATE"]    = "fish / hr"

-- Tooltip of the minimap button and of the addon-compartment entry.
L["TIP_LEFT_CLICK"]  = "Left-click to show the stats window."
L["TIP_RIGHT_CLICK"] = "Right-click for options."

-- ---------------------------------------------------------------------------
-- Chat output. Every line starts with the addon's name; these are the lowercase
-- continuations of that header.

-- Printed when a session ends itself. The two %s are the counted nouns above (casts,
-- then catches); then minutes fished, catches per hour, and the session's gold value.
L["CHAT_SESSION_ENDED"]       = "session ended: %s, %s in %dm (%d/hr)."
L["CHAT_SESSION_ENDED_VALUE"] = "session ended: %s, %s in %dm (%d/hr), ~%dg."

-- Catch alerts. %s is the item (a clickable link), %d how many were caught at once,
-- and the last %s the stack's gold value (it carries its gold icon).
L["ALERT_CATCH"]             = "Nice catch: %s"
L["ALERT_CATCH_COUNT"]       = "Nice catch: %s x%d"
L["ALERT_CATCH_VALUE"]       = "Nice catch: %s (~%s)"
L["ALERT_CATCH_COUNT_VALUE"] = "Nice catch: %s x%d (~%s)"

-- Printed once per login, the first time the window is closed mid-fishing.
L["CHAT_AUTO_OPEN_HINT"] = "Stats window hidden -- it won't auto-open again until after your next fishing break. /ft or the minimap addon drawer reopens it anytime."

-- Saved data written by a newer version of the addon: the two %d are version numbers.
L["CHAT_NEWER_DATA"] = "your saved data is from a newer version (v%d; this build reads v%d). Running without saving -- catches and settings from this session will NOT persist. Please update the addon."

-- Replies to the /ft setting commands. %s is the word the player typed (on, off, rare,
-- zone, ...), which is a command word and stays as typed; %d is a gold amount.
L["CHAT_SET_CAST"]          = "cast mode: %s."
L["CHAT_SET_SESSION"]       = "new sessions start: %s."
L["CHAT_SET_AUTO_LOOT"]     = "auto-loot %s."
L["CHAT_SET_ALERTS"]        = "catch alerts %s."
L["CHAT_SET_ALERT_QUALITY"] = "alert threshold: %s."
L["CHAT_SET_VALUE_ALERTS"]  = "value alerts %s."
L["CHAT_SET_ALERT_VALUE"]   = "value alert threshold: %dg."
L["CHAT_SET_JUNK"]          = "junk items %s."
L["CHAT_SET_JUNK_SORT"]     = "junk sort %s."
L["CHAT_SET_ICONS"]         = "list icons %s."
L["CHAT_SET_PRICES"]        = "auctionator prices %s."
L["CHAT_SET_THEME"]         = "theme set to %s."

-- ---------------------------------------------------------------------------
-- Key Bindings

L["KEYBIND_CAST"] = "Cast Fishing" -- the binding's name in the game's Key Bindings list

-- ---------------------------------------------------------------------------
-- Options panel

L["HEADER_CASTING"]  = "Casting"
L["HEADER_LOOTING"]  = "Looting"
L["HEADER_ALERTS"]   = "Alerts"
L["HEADER_SESSIONS"] = "Sessions"
L["HEADER_WINDOW"]   = "Stats window"

-- Dropdown choices.
L["CHOICE_CAST_OFF"]         = "Disabled"
L["CHOICE_CAST_DOUBLECLICK"] = "Double right-click"
L["CHOICE_CAST_KEY"]         = "Keybind (set in Key Bindings)"
L["CHOICE_CAST_BOTH"]        = "Both"
L["CHOICE_ALERT_RARE"]       = "Rare or better"
L["CHOICE_ALERT_EPIC"]       = "Epic only"
L["CHOICE_SESSION_IDLE"]     = "After inactivity"
L["CHOICE_SESSION_ZONE"]     = "When the zone changes"
L["CHOICE_SESSION_ZONEIDLE"] = "Zone change + inactivity"
L["CHOICE_SESSION_MANUAL"]   = "Manually only"
L["CHOICE_OPEN_OFF"]         = "Disabled"
L["CHOICE_OPEN_FULL"]        = "Full window"
L["CHOICE_OPEN_COMPACT"]     = "Compact view"

-- The value shown beside a slider: seconds, gold, minutes.
L["UNIT_SECONDS"] = "%.2fs"
L["UNIT_GOLD"]    = "%dg"
L["UNIT_MINUTES"] = "%dm"

-- Each setting is a label plus the tooltip shown on hover (_TIP).
L["OPT_CAST_MODE"]         = "Auto-cast"
L["OPT_CAST_MODE_TIP"]     = "How casting is triggered. Off by default -- pick a mode to enable click-to-cast."
L["OPT_CAST_DELAY"]        = "Double-click delay"
L["OPT_CAST_DELAY_TIP"]    = "How quickly the two right-clicks must land to count as a double-click."

L["OPT_AUTO_LOOT"]         = "Auto-loot catches"
L["OPT_AUTO_LOOT_TIP"]     = "Automatically loot everything from a catch. Only applies to fishing loot."

L["OPT_CATCH_ALERTS"]      = "Alert on rare catches"
L["OPT_CATCH_ALERTS_TIP"]  = "Play a sound and print a chat line when you catch something rare. Never opens or moves the stats window."
L["OPT_ALERT_QUALITY"]     = "Alert threshold"
L["OPT_ALERT_QUALITY_TIP"] = "The minimum quality that triggers the alert."
L["OPT_VALUE_ALERTS"]      = "Alert on high-value catches"
L["OPT_VALUE_ALERTS_TIP"]  = "Alert when a single catch's market value meets the threshold below, whatever its quality. Requires the Auctionator addon."
L["OPT_ALERT_VALUE"]       = "Alert when worth at least"
L["OPT_ALERT_VALUE_TIP"]   = "Per-fish market value (from Auctionator) that triggers the alert."

L["OPT_SESSION_END"]       = "Start a new session"
L["OPT_SESSION_END_TIP"]   = "When your next cast begins a fresh session. The finished session stays on screen until you fish again."
L["OPT_SESSION_IDLE"]      = "Inactivity timeout"
L["OPT_SESSION_IDLE_TIP"]  = "How long since your last cast counts as inactivity."
L["OPT_SESSION_PAUSE"]     = "Pause session when not fishing"
L["OPT_SESSION_PAUSE_TIP"] = "Keeps the fish/hour rate honest: each break between casts counts toward the session timer only up to the pause delay below."
L["OPT_SESSION_GRACE"]     = "Pause after"
L["OPT_SESSION_GRACE_TIP"] = "Minutes after your last cast before the session counts as paused. Caps how much of each break the timer counts, and delays the auto-hide below."
L["OPT_AUTO_HIDE"]         = "Auto-hide stats window"
L["OPT_AUTO_HIDE_TIP"]     = "Tucks away the auto-opened stats window (or compact strip) once the session pauses; it returns on your next cast. A window you opened yourself is never hidden."

L["OPT_AUTO_OPEN"]         = "Auto-open when fishing"
L["OPT_AUTO_OPEN_TIP"]     = "What to show when you start fishing: nothing, the full stats window, or the compact strip. Only acts when the window isn't already open -- and if you close it while fishing, it stays closed until your next break."
L["OPT_MINIMAP"]           = "Show minimap button"
L["OPT_MINIMAP_TIP"]       = "Show the Fish & Tips button on the minimap. Either way, the addon stays reachable from the minimap's addon compartment."
L["OPT_INCLUDE_JUNK"]      = "Include junk items"
L["OPT_INCLUDE_JUNK_TIP"]  = "Show gray (junk) catches in the stats window and totals."
L["OPT_SORT_JUNK"]         = "Sort junk below real catches"
L["OPT_SORT_JUNK_TIP"]     = "Keep gray (junk) catches at the bottom of the catch list, below everything else you caught."
L["OPT_LIST_ICONS"]        = "Show item icons"
L["OPT_LIST_ICONS_TIP"]    = "Show each catch's item icon in the stats window list."
L["OPT_PRICES"]            = "Show Auctionator prices"
L["OPT_PRICES_TIP"]        = "Show estimated gold value (from Auctionator) for the current session. Requires the Auctionator addon."

-- Panel footer. %s is the support link, then the addon's version number.
L["FOOTER_DONATE"]  = "Enjoying the addon? Buy me a coffee: %s"
L["FOOTER_VERSION"] = "Version %s"
