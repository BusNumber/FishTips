-- tests/run_tests.lua -- LuaJIT test harness for the data layer (Core.lua + Settings.lua).
-- Runs the REAL addon files against the stubbed WoW API in tests/wow_stubs.lua and
-- asserts the design invariants (DESIGN.md). Anything these stubs can't model
-- (rendering, secure bindings, taint) belongs on the in-game checklist instead.
--
--   luajit tests/run_tests.lua
--
-- Each test loads a fresh addon world via loadAddon(), so tests are independent.

local here = (arg and arg[0] or ""):match("^(.*[/\\])") or ""
local root = here .. "../"
local stubs = dofile(here .. "wow_stubs.lua")
local localeTools = dofile(here .. "locale_tools.lua")

local realPrint = print  -- stubs.install() replaces _G.print; keep the real one for results

-- ---------------------------------------------------------------------------
-- Tiny framework
-- ---------------------------------------------------------------------------
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name = name, fn = fn } end

local function fail(msg) error(msg or "assertion failed", 3) end

local function assertTrue(v, msg)
  if not v then fail((msg or "expected truthy") .. " (got " .. tostring(v) .. ")") end
end

local function assertEq(got, want, msg)
  if got ~= want then
    fail((msg and msg .. ": " or "") .. "expected " .. tostring(want) .. ", got " .. tostring(got))
  end
end

local function deepEqual(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deepEqual(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function deepCopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepCopy(v) end
  return out
end

-- ---------------------------------------------------------------------------
-- Addon loader -- a fresh world per call. Loads the real files with the WoW
-- addon vararg injected (file chunks receive addonName, ns).
-- ---------------------------------------------------------------------------
-- The load list is read from the TOC itself, so the suite boots the files -- in the
-- order -- the game client would (a translation added to the TOC is loaded here too).
-- UI.lua and Casting.lua are in-game-only (frames, secure bindings) and are skipped.
local IN_GAME_ONLY = { ["UI.lua"] = true, ["Casting.lua"] = true }
local ADDON_FILES = {}
for _, file in ipairs(localeTools.tocFiles(root)) do
  if not IN_GAME_ONLY[file] then ADDON_FILES[#ADDON_FILES + 1] = file end
end

-- opts.locale(ns) runs once Locale.lua and the Locales/ files have loaded and BEFORE any
-- other file does -- the place to register a stand-in translation, exactly where a real
-- Locales/xxXX.lua would sit.
local function loadAddon(opts)
  opts = opts or {}
  stubs.install()
  if opts.setup then opts.setup(stubs) end
  _G.FishTipsDB = opts.db
  local ns = {}
  local localeHookRan = false
  for _, file in ipairs(ADDON_FILES) do
    if opts.locale and not localeHookRan and file ~= "Locale.lua" and not file:find("^Locales/") then
      localeHookRan = true
      opts.locale(ns)
    end
    assert(loadfile(root .. file))("FishTips", ns)
  end
  stubs.fire("ADDON_LOADED", "FishTips")
  if not opts.noLogin then stubs.fire("PLAYER_LOGIN") end
  return ns, stubs
end

-- Seed helper: one character's lifetime bucket with a single zone/sub of items.
local function lifeWith(casts, zone, sub, items)
  return { lifetime = { casts = casts, zones = { [zone] = { subs = { [sub] = { items = items } } } } } }
end

-- ---------------------------------------------------------------------------
-- Invariant tests (the DESIGN.md guarantees)
-- ---------------------------------------------------------------------------

test("account_rollup_sums_chars", function()
  local ns = loadAddon({ db = { version = 1, chars = {
    ["Alpha-RealmA"] = lifeWith(10, "Zone1", "SubA", { [111] = { count = 5, quality = 1, name = "FishA" } }),
    ["Beta-RealmB"]  = lifeWith(3,  "Zone1", "SubA", { [111] = { count = 2, quality = 1, name = "FishA" } }),
  } } })
  local a = ns.GetTotals("Alpha-RealmA", "lifetime")
  local b = ns.GetTotals("Beta-RealmB", "lifetime")
  local acc = ns.GetTotals("account", "lifetime")
  assertEq(acc.casts, a.casts + b.casts, "account casts = sum")
  assertEq(acc.catches, a.catches + b.catches, "account catches = sum")
  assertEq(acc.casts, 13)
  assertEq(acc.catches, 7)
  -- Account view merges the same itemID across characters.
  local items = ns.GetLocationItems("account", "lifetime", "Zone1", "SubA")
  assertEq(#items, 1, "same fish merges across chars")
  assertEq(items[1].count, 7)
end)

test("cross_realm_same_name_distinct", function()
  local ns = loadAddon({ db = { version = 1, chars = {
    ["Fisher-RealmA"] = lifeWith(1, "Zone1", "SubA", { [111] = { count = 5, quality = 1 } }),
    ["Fisher-RealmB"] = lifeWith(2, "Zone1", "SubA", { [111] = { count = 9, quality = 1 } }),
  } } })
  local seen = {}
  for _, sc in ipairs(ns.GetScopes()) do seen[sc.key] = true end
  assertTrue(seen["Fisher-RealmA"], "RealmA char in scopes")
  assertTrue(seen["Fisher-RealmB"], "RealmB char in scopes")
  assertEq(ns.GetTotals("Fisher-RealmA", "lifetime").catches, 5)
  assertEq(ns.GetTotals("Fisher-RealmB", "lifetime").catches, 9)
  assertEq(ns.GetTotals("account", "lifetime").catches, 14, "account sums both realms")
end)

test("include_junk_filter_consistent", function()
  local key = "Tester-TestRealm"  -- matches the stub identity => the current character
  local ns = loadAddon({ db = { version = 1, chars = {
    [key] = lifeWith(0, "Zone1", "SubA", {
      [111] = { count = 6, quality = 1, name = "FishA" },
      [222] = { count = 4, quality = 0, name = "Junk" },
    }),
  } } })
  ns.GetSettings().includeJunk = false
  assertEq(ns.GetTotals(key, "lifetime").catches, 6, "totals drop junk")
  assertEq(ns.GetZoneTotals(key, "lifetime")[1].catches, 6, "zone chart drops junk")
  local items = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  assertEq(#items, 1, "list drops junk")
  assertEq(items[1].itemID, 111)
  ns.GetSettings().includeJunk = true
  assertEq(ns.GetTotals(key, "lifetime").catches, 10, "junk still recorded while hidden")
  assertEq(#ns.GetLocationItems(key, "lifetime", "Zone1", "SubA"), 2)
end)

test("list_icons_setting_sanitized", function()
  local ns = loadAddon({ db = { version = 1, chars = {}, settings = { listIcons = "garbage" } } })
  assertEq(ns.GetSettings().listIcons, true, "type garbage falls back to the default")
  local ns2 = loadAddon({ db = { version = 1, chars = {}, settings = { listIcons = false } } })
  assertEq(ns2.GetSettings().listIcons, false, "persisted false survives the == nil fill")
end)

test("alert_settings_sanitized", function()
  local ns = loadAddon({ db = { version = 1, chars = {}, settings = {
    catchAlerts = "garbage", alertQuality = "legendary",
  } } })
  assertEq(ns.GetSettings().catchAlerts, true, "type garbage falls back to the default")
  assertEq(ns.GetSettings().alertQuality, "rare", "unknown threshold clamps to rare")
  local ns2 = loadAddon({ db = { version = 1, chars = {}, settings = {
    catchAlerts = false, alertQuality = "epic",
  } } })
  assertEq(ns2.GetSettings().catchAlerts, false, "persisted false survives the == nil fill")
  assertEq(ns2.GetSettings().alertQuality, "epic", "persisted epic survives the clamp")
end)

test("migrate_stamps_fresh_db", function()
  local ns = loadAddon({})
  assertEq(_G.FishTipsDB.version, 1, "DB version stamped")
  assertEq(_G.FishTipsDB.addonVersion, "test", "addonVersion stamped from TOC")
  assertEq(type(_G.FishTipsDB.chars), "table", "chars table created")
  assertTrue(ns.GetSettings() ~= nil, "settings initialized")
end)

test("session_reset_keeps_lifetime", function()
  local ns, S = loadAddon({})
  local key = ns.CharKey()
  S.fire("UNIT_SPELLCAST_CHANNEL_START", "player", nil, 131476)
  S.setLoot({ { itemID = 111, name = "FishA", quantity = 3, quality = 1 } })
  S.fire("LOOT_OPENED", false)
  assertEq(ns.GetTotals(key, "session").casts, 1, "cast counted")
  assertEq(ns.GetTotals(key, "session").catches, 3, "catch recorded in session")
  assertEq(ns.GetTotals(key, "lifetime").catches, 3, "catch recorded in lifetime")
  ns.ResetSession()
  assertEq(ns.GetTotals(key, "session").catches, 0, "session cleared")
  assertEq(ns.GetTotals(key, "session").casts, 0, "session casts cleared")
  assertEq(ns.GetTotals(key, "lifetime").catches, 3, "lifetime survives reset")
end)

test("locale_lookup_reads_the_table_at_call_time", function()
  local ns = loadAddon({})
  assertEq(ns.L.SCOPE_WARBAND, "Warband", "the base locale supplies the text")
  ns.locales.enUS.SCOPE_WARBAND = "Kriegsmeute"
  local scopes = ns.GetScopes()
  assertEq(scopes[#scopes].name, "Kriegsmeute", "seams read ns.L at call time")
end)

test("fishing_name_resolver_never_caches_fallback", function()
  local ns, S = loadAddon({ setup = function(st) st.spellNames = {} end })
  assertEq(ns.FishingSpellName(), "Fishing", "fallback returned while lookups fail")
  S.spellNames = { [7620] = "P\195\170che" }
  assertEq(ns.FishingSpellName(), "P\195\170che", "a later successful lookup wins (fallback was never cached)")
  S.spellNames = {}
  assertEq(ns.FishingSpellName(), "P\195\170che", "successful lookup memoized")
end)

test("downgrade_guard_leaves_db_untouched", function()
  -- SavedVariables stamped by a hypothetical future version, with fields this build
  -- doesn't know. The guard must not write a single byte to it.
  local db = {
    version = 99,
    futureField = { shape = { 1, 2, 3 } },
    chars = { ["Alpha-RealmA"] = { lifetime = { casts = 5, zones = {} }, futureBit = true } },
    settings = { includeJunk = false },
  }
  local snapshot = deepCopy(db)
  local ns, S = loadAddon({ db = db })
  assertTrue(deepEqual(_G.FishTipsDB, snapshot), "persisted table untouched at load")
  assertTrue(ns.db ~= _G.FishTipsDB, "session runs on a throwaway store")
  -- Tracking still works this session -- on the throwaway.
  S.fire("UNIT_SPELLCAST_CHANNEL_START", "player", nil, 131476)
  S.setLoot({ { itemID = 111, quantity = 2 } })
  S.fire("LOOT_READY", false)
  assertEq(ns.GetTotals(ns.CharKey(), "lifetime").catches, 2, "throwaway store tracks")
  assertTrue(deepEqual(_G.FishTipsDB, snapshot), "still untouched after cast + catch")
  local warnings = 0
  for _, line in ipairs(S.printed) do
    if line:find("newer version", 1, true) then warnings = warnings + 1 end
  end
  assertEq(warnings, 1, "exactly one warning printed")
end)

test("current_version_still_migrates", function()
  loadAddon({ db = { version = 1, chars = {} } })
  assertEq(_G.FishTipsDB.version, 1, "version kept")
  assertEq(_G.FishTipsDB.addonVersion, "test", "addonVersion restamped on the normal path")
end)

-- ---------------------------------------------------------------------------
-- Loot pipeline (LOOT_READY-first, once-per-window, batched refresh)
-- ---------------------------------------------------------------------------

-- Shorthand: fresh world + a fishing channel started (sets fishingActive).
local function loadFishing(opts)
  local ns, S = loadAddon(opts)
  S.fire("UNIT_SPELLCAST_CHANNEL_START", "player", nil, 131476)
  return ns, S
end

test("loot_once_per_window", function()
  -- Native autoloot ON so our LootSlot pass is skipped and the slots persist across
  -- events -- without the guard, three deliveries would triple-count.
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({
    { itemID = 111, quantity = 2 },
    { itemID = 222, quantity = 1 },
    { itemID = 333, quantity = 4 },
  })
  S.fire("LOOT_READY", true)
  S.fire("LOOT_READY", true)   -- the known re-fire quirk
  S.fire("LOOT_OPENED", true)  -- the normal follow-up event
  assertEq(ns.GetTotals(key, "session").catches, 7, "each slot counted exactly once")
end)

test("records_at_loot_ready_alone", function()
  -- Fast-loot scenario: LOOT_OPENED never fires; LOOT_READY must both record and loot.
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({ { itemID = 111, quantity = 2 }, { itemID = 222, quantity = 3 } })
  S.fire("LOOT_READY", false)
  assertEq(ns.GetTotals(key, "session").catches, 5, "recorded at LOOT_READY")
  assertEq(S.lootSlotCalls, 2, "our pass looted every slot")
  assertEq(#S.lootSlots, 0, "reverse loop cleared the re-indexing list")
end)

test("item_rows_carry_link_for_ui", function()
  -- The UI's tooltip/shift-click read row.link (nil tolerated -- demo/legacy records);
  -- the icon reads row.itemID. Assert the seams carry the full row shape.
  local ns, S = loadFishing({ db = { version = 1, chars = {
    ["Tester-TestRealm"] = lifeWith(0, "Zone1", "SubA", {
      [999] = { count = 3, quality = 1, name = "OldFish" },  -- pre-link-capture record
    }),
  } } })
  local key = ns.CharKey()
  S.setLoot({ { itemID = 111, name = "FishA", quantity = 2, quality = 3 } })
  S.fire("LOOT_READY", false)
  local rows = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  local byId = {}
  for _, r in ipairs(rows) do byId[r.itemID] = r end
  assertEq(byId[111].link, "item:111", "live catches carry the stored link")
  assertEq(byId[111].quality, 3, "quality survives the seam")
  assertEq(byId[111].name, "FishA", "name survives the seam")
  assertEq(byId[999].link, nil, "legacy record renders with no link")
  assertEq(byId[999].name, "OldFish", "legacy record keeps its name")
  local sess = ns.GetSessionItems(key)
  assertEq(sess[1].itemID, 111)
  assertEq(sess[1].link, "item:111", "session rows carry the link too")
end)

test("mixed_quality_window_stores_all_qualities", function()
  -- The catch-alert threshold and the "New!" marker read quality straight off the
  -- store; pin that a mixed window writes every slot's quality faithfully, once.
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({
    { itemID = 100, name = "Gray",   quantity = 1, quality = 0 },
    { itemID = 101, name = "White",  quantity = 2, quality = 1 },
    { itemID = 103, name = "Blue",   quantity = 1, quality = 3 },
    { itemID = 104, name = "Purple", quantity = 1, quality = 4 },
  })
  S.fire("LOOT_READY", false)
  for _, bucket in ipairs({ "lifetime", "session" }) do
    local items = _G.FishTipsDB.chars[key][bucket].zones[S.zone].subs[S.sub].items
    assertEq(items[100].quality, 0, bucket .. " stores poor quality")
    assertEq(items[101].quality, 1, bucket .. " stores common quality")
    assertEq(items[103].quality, 3, bucket .. " stores rare quality")
    assertEq(items[104].quality, 4, bucket .. " stores epic quality")
  end
  assertEq(ns.GetTotals(key, "session").catches, 5, "every slot recorded exactly once")
end)

test("empty_window_fires_no_refresh", function()
  -- A window with nothing recordable (money only) must not repaint the UI --
  -- pins the recorded > 0 conditional that the catch-alert fire sits beside.
  local ns, S = loadFishing()
  local refreshes = 0
  ns.RegisterRefresh(function() refreshes = refreshes + 1 end)
  S.setLoot({ { link = false }, { link = false } })  -- two money slots
  S.fire("LOOT_READY", false)
  assertEq(refreshes, 0, "no refresh for a window with nothing recorded")
  assertEq(S.lootSlotCalls, 2, "money slots still looted")
end)

test("alert_fires_once_per_window_with_payload", function()
  -- Native autoloot ON so the slots persist across the re-fired events -- without the
  -- once-per-window guard covering alerts, three deliveries would mean three sounds.
  local ns, S = loadFishing()
  local fires, last = 0, nil
  ns.RegisterCatchAlert(function(items) fires = fires + 1; last = items end)
  S.setLoot({
    { itemID = 111, name = "BlueFish", quantity = 2, quality = 3 },
    { itemID = 222, name = "GrayJunk", quantity = 1, quality = 0 },
  })
  S.fire("LOOT_READY", true)
  S.fire("LOOT_READY", true)
  S.fire("LOOT_OPENED", true)
  assertEq(fires, 1, "one alert per window across re-fired events")
  assertEq(#last, 1, "only the rare slot qualifies")
  assertEq(last[1].itemID, 111)
  assertEq(last[1].name, "BlueFish", "payload carries the name")
  assertEq(last[1].link, "item:111", "payload carries the link")
  assertEq(last[1].quality, 3, "payload carries the quality")
  assertEq(last[1].count, 2, "payload carries the quantity")
end)

test("two_rares_one_window_single_fire", function()
  local ns, S = loadFishing()
  local fires, last = 0, nil
  ns.RegisterCatchAlert(function(items) fires = fires + 1; last = items end)
  S.setLoot({
    { itemID = 111, quantity = 1, quality = 3 },
    { itemID = 222, quantity = 1, quality = 4 },
  })
  S.fire("LOOT_READY", false)
  assertEq(fires, 1, "two alert-worthy items, still one fire (one sound)")
  assertEq(#last, 2, "both items in the payload")
  S.fire("LOOT_CLOSED")
  -- Two slots of the SAME rare merge into one payload entry with the summed count.
  S.setLoot({
    { itemID = 333, quantity = 1, quality = 3 },
    { itemID = 333, quantity = 2, quality = 3 },
  })
  S.fire("LOOT_READY", false)
  assertEq(fires, 2)
  assertEq(#last, 1, "same itemID merged")
  assertEq(last[1].count, 3, "counts summed across slots")
end)

test("below_threshold_no_alert", function()
  local ns, S = loadFishing()
  local fires = 0
  ns.RegisterCatchAlert(function() fires = fires + 1 end)
  S.setLoot({
    { itemID = 111, quantity = 1, quality = 1 },
    { itemID = 222, quantity = 1, quality = 2 },
  })
  S.fire("LOOT_READY", false)
  assertEq(fires, 0, "common/uncommon catches never alert at the rare threshold")
end)

test("alerts_off_no_fire_still_records", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  ns.GetSettings().catchAlerts = false
  local fires = 0
  ns.RegisterCatchAlert(function() fires = fires + 1 end)
  S.setLoot({ { itemID = 111, quantity = 1, quality = 4 } })
  S.fire("LOOT_READY", false)
  assertEq(fires, 0, "setting off silences the notifier")
  assertEq(ns.GetTotals(key, "session").catches, 1, "tracking unaffected")
end)

test("epic_threshold_filters_rares", function()
  local ns, S = loadFishing()
  ns.GetSettings().alertQuality = "epic"
  local fires = 0
  ns.RegisterCatchAlert(function() fires = fires + 1 end)
  S.setLoot({ { itemID = 111, quantity = 1, quality = 3 } })
  S.fire("LOOT_READY", false)
  assertEq(fires, 0, "rare stays silent at the epic threshold")
  S.fire("LOOT_CLOSED")
  S.setLoot({ { itemID = 222, quantity = 1, quality = 4 } })
  S.fire("LOOT_READY", false)
  assertEq(fires, 1, "epic alerts at the epic threshold")
end)

test("alertall_override_alerts_on_common_catches", function()
  -- Dev override (/ft alertall): every recorded catch alerts, via an ns flag that is
  -- never a setting -- so it cannot be persisted and clears at the next login/reload.
  local ns, S = loadFishing()
  local fires, last = 0, nil
  ns.RegisterCatchAlert(function(items) fires = fires + 1; last = items end)
  _G.SlashCmdList["FISHTIPS"]("alertall on")
  S.setLoot({ { itemID = 111, quantity = 1, quality = 1 } })
  S.fire("LOOT_READY", false)
  assertEq(fires, 1, "a common catch alerts under the override")
  assertEq(last[1].quality, 1, "payload carries the real quality")
  assertEq(ns.GetSettings().alertAllCatches, nil, "override never lands in saved settings")
  S.fire("LOOT_CLOSED")
  ns.GetSettings().catchAlerts = false
  S.setLoot({ { itemID = 222, quantity = 1, quality = 1 } })
  S.fire("LOOT_READY", false)
  assertEq(fires, 1, "the override does not bypass the enable gate")
  _G.SlashCmdList["FISHTIPS"]("alertall off")
  assertEq(ns.alertAllCatches, false, "slash toggles the flag off")
end)

test("non_fishing_loot_no_alert", function()
  local ns, S = loadAddon({})  -- no channel, IsFishingLoot stays false
  local fires = 0
  ns.RegisterCatchAlert(function() fires = fires + 1 end)
  S.setLoot({ { itemID = 111, quantity = 1, quality = 4 } })
  S.fire("LOOT_READY", false)
  S.fire("LOOT_OPENED", false)
  assertEq(fires, 0, "an epic mob/chest drop never alerts (not recorded, so not alerted)")
end)

test("opened_fallback_when_ready_missing", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({ { itemID = 111, quantity = 3 } })
  S.fire("LOOT_OPENED", false)
  assertEq(ns.GetTotals(key, "session").catches, 3, "LOOT_OPENED fallback records")
end)

test("native_autoloot_records_without_lootslot", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({ { itemID = 111, quantity = 2 } })
  S.fire("LOOT_READY", true)  -- client is natively auto-looting
  assertEq(ns.GetTotals(key, "session").catches, 2, "still recorded")
  assertEq(S.lootSlotCalls, 0, "no double LootSlot requests")
end)

test("one_refresh_per_window", function()
  local ns, S = loadFishing()
  local refreshes = 0
  ns.RegisterRefresh(function() refreshes = refreshes + 1 end)  -- after the cast's refresh
  S.setLoot({ { itemID = 111 }, { itemID = 222 }, { itemID = 333 } })
  S.fire("LOOT_READY", true)
  S.fire("LOOT_READY", true)
  S.fire("LOOT_OPENED", true)
  assertEq(refreshes, 1, "one refresh per window, not per slot or per event")
end)

test("loot_closed_resets_guard", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({ { itemID = 111, quantity = 1 } })
  S.fire("LOOT_READY", true)
  S.fire("LOOT_CLOSED")
  S.setLoot({ { itemID = 111, quantity = 1 } })
  S.fire("LOOT_READY", true)
  assertEq(ns.GetTotals(key, "session").catches, 2, "second window recorded after LOOT_CLOSED")
end)

test("new_cast_resets_guard", function()
  -- Belt-and-suspenders: if LOOT_CLOSED is ever missed, the next fishing cast unsticks it.
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({ { itemID = 111, quantity = 1 } })
  S.fire("LOOT_READY", true)
  -- no LOOT_CLOSED
  S.fire("UNIT_SPELLCAST_CHANNEL_START", "player", nil, 131476)
  S.setLoot({ { itemID = 111, quantity = 1 } })
  S.fire("LOOT_READY", true)
  assertEq(ns.GetTotals(key, "session").catches, 2, "next cast cleared a stuck guard")
end)

test("non_fishing_loot_ignored", function()
  local ns, S = loadAddon({})  -- no channel, IsFishingLoot stays false
  local key = ns.CharKey()
  S.setLoot({ { itemID = 111, quantity = 5 } })
  S.fire("LOOT_READY", false)
  S.fire("LOOT_OPENED", false)
  assertEq(ns.GetTotals(key, "session").catches, 0, "mob/chest loot never recorded")
  assertEq(S.lootSlotCalls, 0, "mob/chest loot never auto-looted")
end)

test("isfishingloot_gate_alone", function()
  -- Laggy realm: the channel ended long ago (heuristic stale), but IsFishingLoot says yes.
  local ns, S = loadAddon({})
  local key = ns.CharKey()
  S.isFishingLoot = true
  S.setLoot({ { itemID = 111, quantity = 2 } })
  S.fire("LOOT_READY", false)
  assertEq(ns.GetTotals(key, "session").catches, 2, "IsFishingLoot alone gates the window in")
end)

test("heuristic_window_boundary", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", nil, 131476)
  S.advance(0.9)  -- within the 1.0s post-channel window
  S.setLoot({ { itemID = 111, quantity = 1 } })
  S.fire("LOOT_OPENED", false)
  assertEq(ns.GetTotals(key, "session").catches, 1, "loot 0.9s after channel stop records")
  S.fire("LOOT_CLOSED")
  S.advance(0.3)  -- now 1.2s after the stop -> heuristic stale, IsFishingLoot false
  S.setLoot({ { itemID = 222, quantity = 1 } })
  S.fire("LOOT_OPENED", false)
  assertEq(ns.GetTotals(key, "session").catches, 1, "loot 1.2s after channel stop is ignored")
end)

test("money_slot_looted_not_tracked", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({
    { itemID = 111, quantity = 2 },
    { link = false },  -- money slot: GetLootSlotLink returns nil
    { itemID = 222, quantity = 1 },
  })
  S.fire("LOOT_READY", false)
  assertEq(ns.GetTotals(key, "session").catches, 3, "items recorded; money not counted")
  assertEq(S.lootSlotCalls, 3, "money slot still looted")
end)

test("mapid_stamped_on_zone_and_sub", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.mapID = 2369
  S.setLoot({ { itemID = 111, quantity = 1 } })
  S.fire("LOOT_READY", false)
  local z = _G.FishTipsDB.chars[key].lifetime.zones[S.zone]
  assertEq(z.mapID, 2369, "zone bucket stamped")
  assertEq(z.subs[S.sub].mapID, 2369, "sub bucket stamped")
  -- A later catch with an unresolvable map (loading screen) must not erase the ids.
  S.fire("LOOT_CLOSED")
  S.mapID = nil
  S.setLoot({ { itemID = 111, quantity = 1 } })
  S.fire("LOOT_READY", false)
  assertEq(z.mapID, 2369, "nil never overwrites the zone id")
  assertEq(z.subs[S.sub].mapID, 2369, "nil never overwrites the sub id")
end)

test("autoloot_setting_off_still_records", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  ns.GetSettings().autoLoot = false
  S.setLoot({ { itemID = 111, quantity = 4 } })
  S.fire("LOOT_READY", false)
  assertEq(ns.GetTotals(key, "session").catches, 4, "tracking works without auto-loot")
  assertEq(S.lootSlotCalls, 0, "no LootSlot with the setting off")
end)

-- ---------------------------------------------------------------------------
-- Session semantics (lazy end-at-next-cast, active-time clock, reload persistence,
-- whole-session list, pause notifier)
-- ---------------------------------------------------------------------------

local function cast(S) S.fire("UNIT_SPELLCAST_CHANNEL_START", "player", nil, 131476) end
local function stopChannel(S) S.fire("UNIT_SPELLCAST_CHANNEL_STOP", "player", nil, 131476) end
local function catchFish(S, itemID, qty, quality)
  S.setLoot({ { itemID = itemID, quantity = qty or 1, quality = quality or 1 } })
  S.fire("LOOT_READY", false)
  S.fire("LOOT_CLOSED")
end

test("elapsed_zero_before_first_cast_and_caps_gaps", function()
  local ns, S = loadAddon({})
  assertEq(ns.SessionElapsed(), 0, "no clock before the first cast")
  cast(S)
  assertEq(ns.SessionElapsed(), 0, "clock starts at zero on the first cast")
  S.advance(120)  -- 2 min between casts: under the 5-min grace -> counts in full
  assertEq(ns.SessionElapsed(), 120, "short live tail counts in full")
  cast(S)
  assertEq(ns.SessionElapsed(), 120, "short gap accumulated in full")
  S.advance(1200)  -- 20 min idle: tail freezes at the grace
  assertEq(ns.SessionElapsed(), 120 + 300, "live tail capped at the grace")
  cast(S)
  assertEq(ns.SessionElapsed(), 120 + 300, "long gap accumulated capped, no jump")
  ns.GetSettings().sessionPause = false  -- wall-clock mode: gaps count uncapped
  S.advance(1200)
  assertEq(ns.SessionElapsed(), 120 + 300 + 1200, "pause off = wall clock")
end)

test("idle_end_starts_new_session_at_next_cast", function()
  local ns, S = loadAddon({})
  local key = ns.CharKey()
  cast(S)
  catchFish(S, 111, 2)
  S.advance(29 * 60)
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 2, "29-min gap continues the session")
  assertEq(ns.GetTotals(key, "session").catches, 2)
  S.advance(31 * 60)
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 1, "31-min gap starts a new session")
  assertEq(ns.GetTotals(key, "session").catches, 0, "old catches left with the old session")
  assertEq(ns.GetTotals(key, "lifetime").catches, 2, "lifetime intact")
  assertEq(ns.GetTotals(key, "lifetime").casts, 3, "lifetime casts intact")
  local summaries = 0
  for _, line in ipairs(S.printed) do
    if line:find("session ended", 1, true) then summaries = summaries + 1 end
  end
  assertEq(summaries, 1, "exactly one auto-end summary printed")
end)

test("zone_end_mode", function()
  local ns, S = loadAddon({})
  ns.GetSettings().sessionEnd = "zone"
  local key = ns.CharKey()
  cast(S)
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 2, "same zone continues")
  S.zone = "Zone2"
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 1, "zone change starts a new session")
end)

test("zoneidle_requires_both", function()
  local ns, S = loadAddon({})
  ns.GetSettings().sessionEnd = "zoneidle"
  local key = ns.CharKey()
  cast(S)
  S.zone = "Zone2"
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 2, "zone change alone continues")
  S.advance(31 * 60)
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 3, "idle alone continues")
  S.advance(31 * 60)
  S.zone = "Zone3"
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 1, "zone change + idle together end it")
end)

test("manual_mode_never_auto_ends", function()
  local ns, S = loadAddon({})
  ns.GetSettings().sessionEnd = "manual"
  local key = ns.CharKey()
  cast(S)
  S.advance(10 * 3600)
  S.zone = "Zone9"
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 2, "manual mode survives any gap + zone change")
  ns.ResetSession()
  assertEq(ns.GetTotals(key, "session").casts, 0, "the manual button still resets")
end)

test("session_items_merge_across_zones", function()
  local ns, S = loadAddon({})
  local key = ns.CharKey()
  cast(S)
  S.setLoot({
    { itemID = 111, quantity = 2, quality = 1 },
    { itemID = 999, quantity = 1, quality = 0 },
  })
  S.fire("LOOT_READY", false)
  S.fire("LOOT_CLOSED")
  S.zone = "Zone2"; S.sub = "SubB"
  cast(S)  -- small gap, default idle mode -> same session across the zone line
  catchFish(S, 111, 3)
  local items = ns.GetSessionItems(key)
  assertEq(#items, 2, "whole-session list spans both zones")
  assertEq(items[1].itemID, 111, "count-desc order")
  assertEq(items[1].count, 5, "same fish merged across zones")
  ns.GetSettings().includeJunk = false
  items = ns.GetSessionItems(key)
  assertEq(#items, 1, "junk filter honored by the session list")
  assertEq(items[1].itemID, 111)
end)

test("session_rows_resolve_name_and_quality", function()
  -- The isNew derivation lands in GetSessionItems' output loop; pin that session
  -- rows pass through resolveItem intact (name/quality/link) before that changes.
  local ns, S = loadFishing()
  local key = ns.CharKey()
  S.setLoot({ { itemID = 111, name = "FishA", quantity = 2, quality = 3 } })
  S.fire("LOOT_READY", false)
  local rows = ns.GetSessionItems(key)
  assertEq(#rows, 1)
  assertEq(rows[1].name, "FishA", "session row carries the name")
  assertEq(rows[1].quality, 3, "session row carries the quality")
  assertEq(rows[1].link, "item:111", "session row carries the link")
end)

test("session_items_isnew_derivation", function()
  -- "New!" marker: session count == lifetime count <=> every catch of the item ever
  -- happened this session (session records also write to lifetime).
  local ns, S = loadFishing({ db = { version = 1, chars = {
    ["Tester-TestRealm"] = lifeWith(5, "Zone1", "SubA", {
      [999] = { count = 3, quality = 1, name = "OldFish" },
    }),
  } } })
  local key = ns.CharKey()
  local function rowById(id)
    for _, r in ipairs(ns.GetSessionItems(key)) do
      if r.itemID == id then return r end
    end
  end
  catchFish(S, 999, 1)
  assertEq(rowById(999).isNew, false, "a fish with prior lifetime history is not new")
  catchFish(S, 111, 2)
  assertEq(rowById(111).isNew, true, "first-ever catch is new")
  catchFish(S, 111, 1)
  assertEq(rowById(111).isNew, true, "stays new while all its catches are this session")
  catchFish(S, 555, 1, 0)
  assertEq(rowById(555).isNew, true, "the marker is quality-agnostic (junk firsts count)")
  ns.ResetSession()
  catchFish(S, 111, 1)
  assertEq(rowById(111).isNew, false, "a later session sees the lifetime history")
  local lrows = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  for _, r in ipairs(lrows) do
    assertEq(r.isNew, nil, "lifetime rows never carry the marker")
  end
end)

test("session_survives_reload", function()
  local ns, S = loadAddon({})
  local key = ns.CharKey()
  cast(S)
  S.setLoot({ { itemID = 111, quantity = 2 } })
  S.fire("LOOT_READY", false)
  local db = _G.FishTipsDB
  local epoch = S.epoch
  -- "Reload" 3 minutes later: a fresh world on the SAME SavedVariables table.
  local ns2 = loadAddon({ db = db, setup = function(st) st.epoch = epoch + 180 end })
  assertEq(ns2.GetTotals(key, "session").catches, 2, "session restored across reload")
  assertEq(ns2.GetTotals(key, "session").casts, 1, "casts restored")
  assertEq(ns2.SessionElapsed(), 180, "elapsed keeps running on the epoch tail (no dip)")
  -- A 31-minute gap instead: the idle rule judges the reload gap at restore time.
  local ns3 = loadAddon({ db = db, setup = function(st) st.epoch = epoch + 31 * 60 end })
  assertEq(ns3.GetTotals(key, "session").catches, 0, "idle rule ends the session at login")
  assertEq(_G.FishTipsDB.chars[key].session, nil, "stale snapshot dropped from the DB")
end)

test("malformed_snapshot_discarded", function()
  local key = "Tester-TestRealm"  -- matches the stub identity => the current character
  local ns, S = loadAddon({ db = { version = 1, chars = {
    [key] = { lifetime = { casts = 1, zones = {} }, session = "garbage" },
  } } })
  assertEq(ns.GetTotals(key, "session").catches, 0, "no session restored from garbage")
  assertEq(_G.FishTipsDB.chars[key].session, nil, "malformed snapshot discarded")
  cast(S)
  assertEq(ns.GetTotals(key, "session").casts, 1, "a fresh session still works")
end)

test("pause_notifier_fires_once_then_cancels_on_recast", function()
  local ns, S = loadAddon({})
  local fired = 0
  ns.RegisterSessionPause(function() fired = fired + 1 end)
  cast(S)
  S.advance(20)
  stopChannel(S)
  S.advance(600)  -- past lastCast + 5-min grace
  assertEq(fired, 1, "fires once when the grace elapses")
  S.advance(600)
  assertEq(fired, 1, "never re-fires while idle")
  cast(S)
  S.advance(20)
  stopChannel(S)
  cast(S)          -- recast before the grace elapses
  S.advance(600)   -- the superseded timer comes due -> must no-op
  assertEq(fired, 1, "a new cast cancels the pending pause")
  S.advance(20)
  stopChannel(S)
  S.advance(600)
  assertEq(fired, 2, "the pause fires again after the next stop")
end)

test("is_session_idle_lifecycle", function()
  local ns, S = loadAddon({})
  assertTrue(ns.IsSessionIdle(), "idle before any cast")
  cast(S)
  assertEq(ns.IsSessionIdle(), false, "mid-channel is never idle")
  S.advance(20)
  stopChannel(S)
  assertEq(ns.IsSessionIdle(), false, "just stopped: inside the grace")
  S.advance(279)  -- 299s since the cast
  assertEq(ns.IsSessionIdle(), false, "still inside the 5-min grace")
  S.advance(2)    -- 301s since the cast
  assertTrue(ns.IsSessionIdle(), "grace elapsed since the last cast -> idle")
  cast(S)
  assertEq(ns.IsSessionIdle(), false, "the next cast un-idles immediately")
  -- A marathon channel never reads idle while it runs; at stop, the gap since the
  -- CAST governs (mirrors armPauseTimer, whose delay clamps to 0 in that case).
  S.advance(600)
  assertEq(ns.IsSessionIdle(), false, "fishingActive overrides any gap")
  stopChannel(S)
  assertTrue(ns.IsSessionIdle(), "stop after an over-grace channel is immediately idle")
end)

test("is_session_idle_respects_grace_setting", function()
  local ns, S = loadAddon({})
  ns.GetSettings().sessionGraceMinutes = 1
  cast(S)
  S.advance(20)
  stopChannel(S)
  S.advance(45)  -- 65s since the cast: past a 1-min grace
  assertTrue(ns.IsSessionIdle(), "shorter grace respected")
  ns.GetSettings().sessionGraceMinutes = 5
  assertEq(ns.IsSessionIdle(), false, "grace read live: a longer grace un-idles the same gap")
  ns.GetSettings().sessionGraceMinutes = 1
  ns.GetSettings().sessionPause = false
  assertTrue(ns.IsSessionIdle(), "the sessionPause checkbox has no say in idleness")
end)

test("is_session_idle_epoch_fallback_after_reload", function()
  local _, S = loadAddon({})
  cast(S)
  S.advance(20)
  stopChannel(S)
  local db = _G.FishTipsDB
  local epoch = S.epoch
  -- "Reload": lastCastAt is uptime-based and dropped at restore, so the gap must
  -- run on the epoch stamp (which sits 20s behind `epoch` -- stamped at the cast).
  local ns2 = loadAddon({ db = db, setup = function(st) st.epoch = epoch + 100 end })
  assertEq(ns2.IsSessionIdle(), false, "inside the grace on the epoch stamp")
  -- Past the grace but inside the 30-min idle rule, so the session itself restores --
  -- exactly the state the auto-open suppression clear cares about.
  local ns3 = loadAddon({ db = db, setup = function(st) st.epoch = epoch + 360 end })
  assertTrue(ns3.IsSessionIdle(), "past the grace on the epoch stamp")
end)

test("pause_notifier_fires_with_pause_setting_off", function()
  -- Core's contract: the notifier keys off the grace REGARDLESS of the sessionPause
  -- checkbox (that governs only the elapsed-time arithmetic). The UI's auto-open
  -- suppression clear depends on this firing unconditionally.
  local ns, S = loadAddon({})
  ns.GetSettings().sessionPause = false
  local fired = 0
  ns.RegisterSessionPause(function() fired = fired + 1 end)
  cast(S)
  S.advance(20)
  stopChannel(S)
  S.advance(600)
  assertEq(fired, 1, "the pause notifier fires with the checkbox off")
end)

-- ---------------------------------------------------------------------------
-- Catch-list ordering (the item seams' sort contract)
-- ---------------------------------------------------------------------------

test("location_items_nonjunk_count_desc_baseline", function()
  -- Baseline pin: non-junk rows come back count-desc from GetLocationItems. This
  -- must hold before AND after any junk-grouping change (within-group order).
  local key = "Tester-TestRealm"
  local ns = loadAddon({ db = { version = 1, chars = {
    [key] = lifeWith(0, "Zone1", "SubA", {
      [201] = { count = 4, quality = 3, name = "Blue" },
      [202] = { count = 9, quality = 1, name = "White" },
      [203] = { count = 2, quality = 2, name = "Green" },
      [204] = { count = 7, quality = 1, name = "White2" },
    }),
  } } })
  local items = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  assertEq(#items, 4)
  assertEq(items[1].itemID, 202, "highest count first")
  assertEq(items[2].itemID, 204)
  assertEq(items[3].itemID, 201)
  assertEq(items[4].itemID, 203, "lowest count last")
end)

test("session_items_nonjunk_count_desc_baseline", function()
  -- Same pin for the whole-session list.
  local ns, S = loadFishing()
  local key = ns.CharKey()
  catchFish(S, 301, 3)
  catchFish(S, 302, 8)
  catchFish(S, 303, 5)
  local items = ns.GetSessionItems(key)
  assertEq(#items, 3)
  assertEq(items[1].itemID, 302, "highest count first")
  assertEq(items[2].itemID, 303)
  assertEq(items[3].itemID, 301, "lowest count last")
end)

test("nil_quality_resolves_to_common_baseline", function()
  -- Legacy records may lack a quality; resolveItem defaults it to 1 (non-junk) on
  -- the way out of both seams, and the junk filter treats it as non-junk too. The
  -- sort's quality == 0 test leans on this.
  local key = "Tester-TestRealm"
  local ns = loadAddon({ db = { version = 1, chars = {
    [key] = lifeWith(0, "Zone1", "SubA", {
      [401] = { count = 2, name = "NoQuality" },
    }),
  } } })
  local items = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  assertEq(items[1].quality, 1, "nil quality resolves to common")
  ns.GetSettings().includeJunk = false
  assertEq(#ns.GetLocationItems(key, "lifetime", "Zone1", "SubA"), 1,
    "a nil-quality row is non-junk to the filter")
end)

-- Shared seed for the junk-sort tests: junk holds the GLOBAL max count (the crowding
-- case the feature exists for), a second junk, and two non-junk rows.
local function junkSortWorld()
  local key = "Tester-TestRealm"
  local ns = loadAddon({ db = { version = 1, chars = {
    [key] = lifeWith(0, "Zone1", "SubA", {
      [501] = { count = 50, quality = 0, name = "Junk50" },
      [502] = { count = 20, quality = 0, name = "Junk20" },
      [503] = { count = 10, quality = 1, name = "Fish10" },
      [504] = { count = 5,  quality = 3, name = "Fish5" },
    }),
  } } })
  return ns, key
end

test("junk_sorts_below_catches_location", function()
  -- Default on: every non-junk above every junk, count-desc within each group --
  -- even when a junk row holds the list's top count.
  local ns, key = junkSortWorld()
  local items = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  assertEq(#items, 4)
  assertEq(items[1].itemID, 503, "non-junk group first, count-desc")
  assertEq(items[2].itemID, 504)
  assertEq(items[3].itemID, 501, "junk group last, count-desc within it")
  assertEq(items[4].itemID, 502)
end)

test("junk_sorts_below_catches_session", function()
  local ns, S = loadFishing()
  local key = ns.CharKey()
  catchFish(S, 601, 9, 0)  -- junk, top count
  catchFish(S, 602, 2, 1)
  local items = ns.GetSessionItems(key)
  assertEq(#items, 2)
  assertEq(items[1].itemID, 602, "non-junk above the higher-count junk")
  assertEq(items[2].itemID, 601)
end)

test("junk_sort_boundary_tie_nonjunk_first", function()
  -- A count tie across the junk boundary resolves deterministically: non-junk first.
  local key = "Tester-TestRealm"
  local ns = loadAddon({ db = { version = 1, chars = {
    [key] = lifeWith(0, "Zone1", "SubA", {
      [701] = { count = 5, quality = 0, name = "Junk5" },
      [702] = { count = 5, quality = 1, name = "Fish5" },
    }),
  } } })
  local items = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  assertEq(items[1].itemID, 702, "non-junk wins the cross-boundary tie")
  assertEq(items[2].itemID, 701)
end)

test("junk_sort_setting_off_restores_count_desc", function()
  local ns, key = junkSortWorld()
  ns.GetSettings().sortJunkLast = false
  local items = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  assertEq(items[1].itemID, 501, "pure count-desc with the setting off")
  assertEq(items[2].itemID, 502)
  assertEq(items[3].itemID, 503)
  assertEq(items[4].itemID, 504)
end)

test("junk_sort_inert_when_junk_hidden", function()
  -- The nesting's truthfulness claim, data-layer half: with junk hidden there are no
  -- junk rows to order, so the sort setting has no observable effect.
  local ns, key = junkSortWorld()
  ns.GetSettings().includeJunk = false
  local items = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  assertEq(#items, 2, "junk filtered out entirely")
  assertEq(items[1].itemID, 503, "survivors still count-desc")
  assertEq(items[2].itemID, 504)
end)

test("junk_sort_setting_sanitized", function()
  local ns = loadAddon({ db = { version = 1, chars = {}, settings = { sortJunkLast = "garbage" } } })
  assertEq(ns.GetSettings().sortJunkLast, true, "type garbage falls back to the default")
  local ns2 = loadAddon({ db = { version = 1, chars = {}, settings = { sortJunkLast = false } } })
  assertEq(ns2.GetSettings().sortJunkLast, false, "persisted false survives the == nil fill")
end)

test("junk_sort_slash_toggle", function()
  local ns, key = junkSortWorld()
  local refreshes = 0
  ns.RegisterRefresh(function() refreshes = refreshes + 1 end)
  _G.SlashCmdList["FISHTIPS"]("junksort off")
  assertEq(ns.GetSettings().sortJunkLast, false, "slash off writes the setting")
  assertEq(refreshes, 1, "one refresh per toggle")
  assertEq(ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")[1].itemID, 501)
  _G.SlashCmdList["FISHTIPS"]("junksort on")
  assertEq(ns.GetSettings().sortJunkLast, true, "slash on writes the setting")
  assertEq(refreshes, 2)
  assertEq(ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")[1].itemID, 503)
end)

test("nil_quality_sorts_as_non_junk", function()
  -- Legacy nil-quality records resolve to quality 1, so they sort with the non-junk
  -- group -- above junk even at a fraction of its count.
  local key = "Tester-TestRealm"
  local ns = loadAddon({ db = { version = 1, chars = {
    [key] = lifeWith(0, "Zone1", "SubA", {
      [801] = { count = 50, quality = 0, name = "Junk50" },
      [802] = { count = 1, name = "LegacyNoQuality" },
    }),
  } } })
  local items = ns.GetLocationItems(key, "lifetime", "Zone1", "SubA")
  assertEq(items[1].itemID, 802, "nil-quality row sorts as non-junk")
  assertEq(items[2].itemID, 801)
end)

-- ---------------------------------------------------------------------------
-- Auctionator pricing seams (baseline pins -- landed BEFORE the gold/hr and
-- value-alert features so the pre-feature contract those stack on is pinned)
-- ---------------------------------------------------------------------------

test("pricing_inactive_without_auctionator_baseline", function()
  -- Baseline pin: with the setting at its default (on) but no Auctionator installed,
  -- every pricing seam reads "off". Must hold before AND after gold/hr + value alerts.
  local ns = loadAddon({})
  assertEq(ns.PricingActive(), false, "no Auctionator => pricing inactive")
  assertEq(ns.GetItemPrice(111), nil, "no Auctionator => no unit price")
  assertEq(ns.GetSessionValue(), nil, "no Auctionator => no session value")
end)

test("pricing_seams_with_stub_baseline", function()
  -- Baseline pin: the seam contract against a present API -- copper unit price,
  -- string itemID coerced, nil for unscanned items. The auctionatorPrices setting is
  -- the DISPLAY off switch (PricingActive/GetSessionValue); the raw price lookup keys
  -- on Auctionator's presence alone, so the decoupled value alerts can price catches
  -- while the overlay is hidden.
  local ns, S = loadAddon({})
  S.setPrices({ [111] = 250000 })  -- 25g
  assertEq(ns.PricingActive(), true, "setting on + API present => active")
  assertEq(ns.GetItemPrice(111), 250000, "unit price in copper")
  assertEq(ns.GetItemPrice("111"), 250000, "string itemID coerced to a number")
  assertEq(ns.GetItemPrice(999), nil, "no scanned data => nil")
  ns.GetSettings().auctionatorPrices = false
  assertEq(ns.PricingActive(), false, "the setting alone turns the overlay off")
  assertEq(ns.GetItemPrice(111), 250000, "unit price is presence-gated, not setting-gated")
  assertEq(ns.GetSessionValue(), nil, "session value gated by the setting")
end)

test("session_value_math_and_junk_filter_baseline", function()
  -- Baseline pin: GetSessionValue = sum(count x unit) over the live session, skipping
  -- unpriced items and honoring includeJunk -- the base the gold/hr rate divides.
  local ns, S = loadFishing()
  S.setPrices({ [111] = 100000, [222] = 30000 })  -- 10g, 3g; 333 stays unpriced
  catchFish(S, 111, 2, 1)
  catchFish(S, 222, 3, 0)  -- gray
  catchFish(S, 333, 1, 1)  -- no price data => contributes 0, not "?"
  assertEq(ns.GetSessionValue(), 2 * 100000 + 3 * 30000, "sum of priced catches")
  ns.GetSettings().includeJunk = false
  assertEq(ns.GetSessionValue(), 200000, "hidden gray's value drops from the total")
end)

test("lifetime_rate_nil_baseline", function()
  -- Baseline pin: lifetime totals never carry a rate -- there is no lifetime clock,
  -- and the footer-honesty fix must keep that absence rather than fabricate a number.
  local key = "Tester-TestRealm"
  local ns = loadAddon({ db = { version = 1, chars = {
    [key] = lifeWith(10, "Zone1", "SubA", { [111] = { count = 5, quality = 1 } }),
  } } })
  assertEq(ns.GetTotals(key, "lifetime").ratePerHour, nil, "no fabricated lifetime rate")
end)

test("auctionator_presence_never_alerts_baseline", function()
  -- Baseline pin: prices alone never alert -- quality is the only alert path today.
  -- After the value-alert feature ships (default OFF), this same world doubles as its
  -- default-off proof: an expensive common catch stays silent until the player opts in.
  local ns, S = loadFishing()
  S.setPrices({ [111] = 5000000 })  -- a 500g common fish
  local fires = 0
  ns.RegisterCatchAlert(function() fires = fires + 1 end)
  catchFish(S, 111, 1, 1)
  assertEq(fires, 0, "an expensive common catch stays silent")
end)

-- ---------------------------------------------------------------------------
-- Footer honesty + gold/hr (lifetime totals carry no clock; the value rate seam)
-- ---------------------------------------------------------------------------

test("lifetime_totals_carry_no_clock", function()
  -- Lifetime elapsed is nil now (was: the live session clock, a fabricated number
  -- the old always-session footer leaned on); the session table keeps its clock.
  local ns, S = loadAddon({})
  cast(S)
  S.advance(60)
  cast(S)
  local key = ns.CharKey()
  assertEq(ns.GetTotals(key, "lifetime").elapsed, nil, "no lifetime clock")
  assertEq(ns.GetTotals(key, "lifetime").ratePerHour, nil, "no lifetime rate")
  assertEq(ns.GetTotals(key, "session").elapsed, 60, "session clock intact")
  assertTrue(ns.GetTotals(key, "session").ratePerHour ~= nil, "session rate intact")
end)

test("session_value_rate_math_and_nil_cases", function()
  local ns, S = loadAddon({})
  assertEq(ns.GetSessionValueRate(), nil, "no rate without Auctionator")
  S.setPrices({ [111] = 100000 })  -- 10g
  assertEq(ns.GetSessionValueRate(), nil, "no rate before the first cast (clock at zero)")
  cast(S)
  catchFish(S, 111, 2, 1)  -- 20g in the session
  S.advance(120)           -- 2 min of active time (under the grace)
  cast(S)
  -- 200000 copper over 120s of active time -> 200000 / (120/3600) = 6,000,000 c/hr.
  assertEq(ns.GetSessionValueRate(), 6000000, "value / active hours, integer copper")
  ns.GetSettings().auctionatorPrices = false
  assertEq(ns.GetSessionValueRate(), nil, "pricing off => no rate")
end)

-- ---------------------------------------------------------------------------
-- Value-based catch alerts (the second, independent alert path)
-- ---------------------------------------------------------------------------

test("value_alert_fires_on_cheap_quality_expensive_fish", function()
  local ns, S = loadFishing()
  ns.GetSettings().valueAlerts = true
  S.setPrices({ [111] = 2000000 })  -- 200g unit >= the 100g default threshold
  local fires, last = 0, nil
  ns.RegisterCatchAlert(function(items) fires = fires + 1; last = items end)
  catchFish(S, 111, 2, 1)  -- common quality
  assertEq(fires, 1, "value path fires without quality")
  assertEq(#last, 1)
  assertEq(last[1].itemID, 111)
  assertEq(last[1].count, 2)
  assertEq(last[1].value, 2 * 2000000, "payload value = unit x merged count")
end)

test("value_alert_unit_basis_stack_never_qualifies", function()
  -- The threshold judges the UNIT price: a pile of cheap fish never alerts,
  -- however much the stack is worth in total.
  local ns, S = loadFishing()
  ns.GetSettings().valueAlerts = true
  S.setPrices({ [111] = 300000 })  -- 30g each; 5 of them = 150g > threshold
  local fires = 0
  ns.RegisterCatchAlert(function() fires = fires + 1 end)
  catchFish(S, 111, 5, 1)
  assertEq(fires, 0, "stack total never qualifies")
end)

test("value_alerts_ignore_overlay_setting", function()
  -- The decoupling pin: the price OVERLAY and the value ALERT are separate features.
  -- With "Show Auctionator prices" off (no prices anywhere in the window), a
  -- threshold-passing catch still alerts -- only Auctionator's presence is required.
  local ns, S = loadFishing()
  ns.GetSettings().valueAlerts = true
  ns.GetSettings().auctionatorPrices = false
  S.setPrices({ [111] = 5000000 })
  local fires, last = 0, nil
  ns.RegisterCatchAlert(function(items) fires = fires + 1; last = items end)
  catchFish(S, 111, 1, 1)
  assertEq(fires, 1, "overlay off does not silence the value alert")
  assertEq(last[1].value, 5000000, "payload still carries the value")
  assertEq(ns.GetSessionValue(), nil, "the overlay itself stays off")
end)

test("value_alert_without_auctionator_no_error", function()
  local ns, S = loadFishing()
  ns.GetSettings().valueAlerts = true  -- opted in, but no Auctionator installed
  local fires = 0
  ns.RegisterCatchAlert(function() fires = fires + 1 end)
  catchFish(S, 111, 1, 1)
  assertEq(fires, 0, "no Auctionator => silent, no error")
  assertEq(ns.GetTotals(ns.CharKey(), "session").catches, 1, "catch still records")
end)

test("mixed_quality_value_window_single_fire", function()
  local ns, S = loadFishing()
  ns.GetSettings().valueAlerts = true
  S.setPrices({ [222] = 1500000 })  -- the white fish is worth 150g; the rare unpriced
  local fires, last = 0, nil
  ns.RegisterCatchAlert(function(items) fires = fires + 1; last = items end)
  S.setLoot({
    { itemID = 111, name = "BlueFish", quantity = 1, quality = 3 },
    { itemID = 222, name = "RichWhite", quantity = 1, quality = 1 },
  })
  S.fire("LOOT_READY", false)
  assertEq(fires, 1, "one sound for a mixed rare+value window")
  assertEq(#last, 2, "both entries in the one payload")
  local byId = {}
  for _, a in ipairs(last) do byId[a.itemID] = a end
  assertEq(byId[111].value, nil, "quality-only entry carries no value")
  assertEq(byId[222].value, 1500000, "value entry carries the stack value")
end)

test("value_and_quality_qualified_single_entry", function()
  local ns, S = loadFishing()
  ns.GetSettings().valueAlerts = true
  S.setPrices({ [111] = 2000000 })
  local fires, last = 0, nil
  ns.RegisterCatchAlert(function(items) fires = fires + 1; last = items end)
  catchFish(S, 111, 1, 3)  -- rare AND expensive
  assertEq(fires, 1)
  assertEq(#last, 1, "both paths merge into one entry")
  assertEq(last[1].quality, 3)
  assertEq(last[1].value, 2000000)
end)

test("same_item_slots_merge_value", function()
  local ns, S = loadFishing()
  ns.GetSettings().valueAlerts = true
  S.setPrices({ [111] = 2000000 })
  local last
  ns.RegisterCatchAlert(function(items) last = items end)
  S.setLoot({
    { itemID = 111, quantity = 2, quality = 1 },
    { itemID = 111, quantity = 1, quality = 1 },
  })
  S.fire("LOOT_READY", false)
  assertEq(#last, 1, "same item merges to one entry")
  assertEq(last[1].count, 3)
  assertEq(last[1].value, 3 * 2000000, "value recomputed from the merged count")
end)

test("value_alerts_independent_of_catch_alerts", function()
  -- "Alert on rare catches" is quality-specific by label; turning it off must not
  -- silence the value path -- and under it, an unpriced rare stays silent.
  local ns, S = loadFishing()
  ns.GetSettings().catchAlerts = false
  ns.GetSettings().valueAlerts = true
  S.setPrices({ [111] = 2000000 })
  local fires, last = 0, nil
  ns.RegisterCatchAlert(function(items) fires = fires + 1; last = items end)
  S.setLoot({
    { itemID = 111, name = "RichWhite", quantity = 1, quality = 1 },
    { itemID = 222, name = "PoorRare", quantity = 1, quality = 3 },  -- unpriced rare
  })
  S.fire("LOOT_READY", false)
  assertEq(fires, 1, "value path fires with quality alerts off")
  assertEq(#last, 1, "the unpriced rare stays out of the payload")
  assertEq(last[1].itemID, 111)
end)

test("value_alert_settings_sanitized", function()
  local ns = loadAddon({ db = { version = 1, chars = {}, settings = {
    valueAlerts = "garbage", alertValueGold = "lots",
  } } })
  assertEq(ns.GetSettings().valueAlerts, false, "type garbage falls back to the default (off)")
  assertEq(ns.GetSettings().alertValueGold, 100, "type garbage falls back to 100g")
  local ns2 = loadAddon({ db = { version = 1, chars = {}, settings = {
    valueAlerts = true, alertValueGold = 5,
  } } })
  assertEq(ns2.GetSettings().valueAlerts, true, "persisted true survives the == nil fill")
  assertEq(ns2.GetSettings().alertValueGold, 10, "below-range clamps up to 10")
  local ns3 = loadAddon({ db = { version = 1, chars = {}, settings = { alertValueGold = 5000 } } })
  assertEq(ns3.GetSettings().alertValueGold, 1000, "above-range clamps down to 1000")
end)

test("value_alert_slash", function()
  local ns, S = loadAddon({})
  _G.SlashCmdList["FISHTIPS"]("alerts value on")
  assertEq(ns.GetSettings().valueAlerts, true, "slash on writes the setting")
  _G.SlashCmdList["FISHTIPS"]("alerts value 250")
  assertEq(ns.GetSettings().alertValueGold, 250, "slash sets the threshold")
  _G.SlashCmdList["FISHTIPS"]("alerts value 25000")
  assertEq(ns.GetSettings().alertValueGold, 1000, "out-of-range input clamps")
  local echoed = false
  for _, line in ipairs(S.printed) do
    if line:find("1000g", 1, true) then echoed = true end
  end
  assertTrue(echoed, "the applied (clamped) value is echoed back")
  _G.SlashCmdList["FISHTIPS"]("alerts value off")
  assertEq(ns.GetSettings().valueAlerts, false, "slash off writes the setting")
  _G.SlashCmdList["FISHTIPS"]("alerts off")
  assertEq(ns.GetSettings().catchAlerts, false, "the plain on/off path still works")
end)

-- ---------------------------------------------------------------------------
-- Session-end summary value
-- ---------------------------------------------------------------------------

test("summary_includes_value_when_priced", function()
  local _, S = loadAddon({})
  S.setPrices({ [111] = 100000 })  -- 10g
  cast(S)
  catchFish(S, 111, 2, 1)  -- a 20g session
  S.advance(31 * 60)
  cast(S)  -- idle end -> the old session's summary prints before it retires
  local line
  for _, l in ipairs(S.printed) do
    if l:find("session ended", 1, true) then line = l end
  end
  assertTrue(line ~= nil, "summary printed")
  assertTrue(line:find("~20g", 1, true) ~= nil, "summary carries the session value")
end)

test("summary_plain_without_pricing", function()
  local _, S = loadAddon({})
  cast(S)
  catchFish(S, 111, 2, 1)
  S.advance(31 * 60)
  cast(S)
  local line
  for _, l in ipairs(S.printed) do
    if l:find("session ended", 1, true) then line = l end
  end
  assertTrue(line ~= nil, "summary printed")
  assertEq(line:find("~", 1, true), nil, "no value fragment without pricing")
end)

test("summary_value_demo_guarded", function()
  -- A real session's closing line must never print a demo-derived figure --
  -- GetSessionValue reads through the demo-poisoned session scope.
  local ns, S = loadAddon({})
  S.setPrices({ [111] = 100000 })
  cast(S)
  catchFish(S, 111, 2, 1)
  ns.demoOn = true
  S.advance(31 * 60)
  cast(S)
  ns.demoOn = false
  local line
  for _, l in ipairs(S.printed) do
    if l:find("session ended", 1, true) then line = l end
  end
  assertTrue(line ~= nil, "summary still printed under demo")
  assertEq(line:find("~", 1, true), nil, "demo on => no value in the summary")
end)

-- ---------------------------------------------------------------------------
-- Localization: exact English text (the "nothing changes in English" pins), the
-- options panel's strings, and the static key lint
-- ---------------------------------------------------------------------------

local PREFIX = "|cffffd36eFish & Tips|r: "

-- The last printed line containing `fragment` (default: the English session summary).
local function summaryLine(S, fragment)
  local line
  for _, l in ipairs(S.printed) do
    if l:find(fragment or "session ended", 1, true) then line = l end
  end
  return line
end

-- Run a slash command and return the line it printed.
local function slash(S, msg)
  local before = #S.printed
  _G.SlashCmdList["FISHTIPS"](msg)
  assertEq(#S.printed, before + 1, "/ft " .. msg .. " prints exactly one line")
  return S.printed[#S.printed]
end

test("english_summary_line_exact", function()
  -- 2 casts 120s apart + the capped 5-min tail = 420s active; 3 catches -> 26/hr.
  local _, S = loadAddon({})
  cast(S)
  catchFish(S, 111, 2, 1)
  S.advance(120)
  cast(S)
  catchFish(S, 111, 1, 1)
  S.advance(31 * 60)
  cast(S)
  assertEq(summaryLine(S), PREFIX .. "session ended: 2 casts, 3 catches in 7m (26/hr).")
end)

test("english_summary_line_exact_priced", function()
  local _, S = loadAddon({})
  S.setPrices({ [111] = 100000 })  -- 10g each
  cast(S)
  catchFish(S, 111, 2, 1)
  S.advance(120)
  cast(S)
  catchFish(S, 111, 1, 1)
  S.advance(31 * 60)
  cast(S)
  assertEq(summaryLine(S), PREFIX .. "session ended: 2 casts, 3 catches in 7m (26/hr), ~30g.")
end)

test("english_summary_line_exact_singular", function()
  local _, S = loadAddon({})
  cast(S)
  catchFish(S, 111, 1, 1)
  S.advance(31 * 60)
  cast(S)
  -- The one English line that changed with the plural hook: this used to read
  -- "1 casts, 1 catches".
  assertEq(summaryLine(S), PREFIX .. "session ended: 1 cast, 1 catch in 5m (12/hr).")
end)

test("english_downgrade_warning_exact", function()
  local _, S = loadAddon({ db = { version = 99, chars = {} } })
  assertEq(S.printed[1], PREFIX .. "your saved data is from a newer version (v99; this build reads v1). "
    .. "Running without saving -- catches and settings from this session will NOT persist. "
    .. "Please update the addon.")
end)

test("english_slash_output_exact", function()
  local _, S = loadAddon({})
  local function expect(msg, want) assertEq(slash(S, msg), PREFIX .. want, "/ft " .. msg) end
  expect("cast key", "cast mode: key.")
  expect("cast", "cast: off | doubleclick | key | both")
  expect("session zone", "new sessions start: zone.")
  expect("session", "session: manual | idle | zone | zoneidle  (currently zone)")
  expect("autoloot off", "auto-loot off.")
  expect("autoloot", "autoloot: on | off  (currently off)")
  expect("alerts off", "catch alerts off.")
  expect("alerts epic", "alert threshold: epic.")
  expect("alerts value on", "value alerts on.")
  expect("alerts value 250", "value alert threshold: 250g.")
  expect("alerts value", "alerts value: on | off | <10-1000>  (currently on, 250g)")
  expect("alerts", "alerts: on | off | rare | epic | value ...  (currently off, epic; value on, 250g)")
  expect("junk off", "junk items off.")
  expect("junk", "junk: on | off  (currently off)")
  expect("junksort off", "junk sort off.")
  expect("junksort", "junksort: on | off  (currently off)")
  expect("icons off", "list icons off.")
  expect("icons", "icons: on | off  (currently off)")
  expect("auc off", "auctionator prices off.")
  expect("auc", "auc: on | off  (currently off)")
  expect("theme classic", "theme set to classic.")
  expect("theme", "theme: classic | modern | blend")
  expect("bogus", "commands: /ft  (toggle)  |  config  |  cast off|doubleclick|key|both  |  "
    .. "session manual|idle|zone|zoneidle  |  autoloot on|off  |  alerts on|off|rare|epic  |  "
    .. "alerts value on|off|<gold>  |  junk on|off  |  junksort on|off  |  icons on|off  |  "
    .. "auc on|off  |  demo on|off")
end)

test("options_panel_registers_cleanly", function()
  local ns, S = loadAddon({ setup = function(st) st.installSettingsPanel() end })
  local panel = S.panel
  assertTrue(panel.registered, "the category was registered")
  assertEq(panel.categoryName, "Fish & Tips", "the brand names the category")
  assertEq(#panel.controls, 18, "every option is registered")
  for _, c in ipairs(panel.controls) do
    assertTrue(type(c.name) == "string" and c.name ~= "", c.key .. " has a label")
    assertTrue(type(c.tooltip) == "string" and c.tooltip ~= "", c.key .. " has a tooltip")
    -- RegisterAddOnSetting reads/writes db.settings by key; the VarType comes from the
    -- default's Lua type (a mismatch is an in-game-only failure otherwise).
    assertEq(c.setting.tbl, ns.GetSettings(), c.key .. " binds the live settings table")
    assertTrue(c.default ~= nil, c.key .. " has a default")
    assertEq(c.varType, type(c.default), c.key .. " VarType matches its default")
    assertEq(type(c.setting.tbl[c.key]), c.varType, c.key .. " stored value matches the VarType")
    if c.kind == "dropdown" then
      local options = c.options()
      assertTrue(#options > 0, c.key .. " has options")
      for _, o in ipairs(options) do
        assertTrue(type(o.label) == "string" and o.label ~= "", c.key .. " option label")
      end
    end
  end
  for _, h in ipairs(panel.headers) do
    assertTrue(type(h) == "string" and h ~= "", "section header text")
  end
  -- The truthful gray-outs: each nested control sits under the setting it depends on.
  local nesting = {
    castDelay = "castMode", alertQuality = "catchAlerts", alertValueGold = "valueAlerts",
    sessionIdleMinutes = "sessionEnd", sessionGraceMinutes = "sessionPause",
    autoHide = "sessionPause", sortJunkLast = "includeJunk",
  }
  for _, c in ipairs(panel.controls) do
    assertEq(c.parent and c.parent.key or nil, nesting[c.key], c.key .. " nesting")
  end
end)

test("english_options_slider_labels_exact", function()
  local _, S = loadAddon({ setup = function(st) st.installSettingsPanel() end })
  local function label(key, value) return S.panel.byKey[key].sliderOptions.formatter(value) end
  assertEq(label("castDelay", 0.3), "0.30s")
  assertEq(label("alertValueGold", 100), "100g")
  assertEq(label("sessionIdleMinutes", 30), "30m")
  assertEq(label("sessionGraceMinutes", 5), "5m")
end)

-- A scripted outing that touches everything stored: casts and catches in two zones, a
-- junk catch, settings changed through slash commands, and a session that ends itself.
-- Returns a deep copy of the resulting SavedVariables.
local function storedDataAfterOuting(opts)
  local _, S = loadAddon(opts)
  cast(S)
  S.setLoot({ { itemID = 111, name = "FishA", quantity = 2, quality = 1 } })
  S.fire("LOOT_READY", false)
  S.fire("LOOT_CLOSED")
  S.advance(90)
  S.zone, S.sub, S.mapID = "Zone2", "SubB", 1600
  cast(S)
  S.setLoot({ { itemID = 222, name = "Junk", quantity = 1, quality = 0 } })
  S.fire("LOOT_READY", false)
  S.fire("LOOT_CLOSED")
  _G.SlashCmdList["FISHTIPS"]("alerts epic")
  _G.SlashCmdList["FISHTIPS"]("junk off")
  S.advance(31 * 60)
  cast(S)  -- idle end: the summary prints and a fresh session starts
  catchFish(S, 111, 1, 1)
  return deepCopy(_G.FishTipsDB), S
end

test("stored_data_outing_is_deterministic", function()
  local db = storedDataAfterOuting({})
  local again = storedDataAfterOuting({})
  assertTrue(deepEqual(db, again), "the same outing stores the same data")
  local me = db.chars["Tester-TestRealm"]
  assertEq(me.lifetime.casts, 3)
  assertEq(me.lifetime.zones["Zone1"].subs["SubA"].items[111].name, "FishA", "item names stored as looted")
  assertEq(me.lifetime.zones["Zone2"].subs["SubB"].items[222].count, 1)
  assertEq(db.settings.alertQuality, "epic", "setting values are tokens")
  assertEq(db.settings.includeJunk, false)
end)

-- ---------------------------------------------------------------------------
-- The string table (Locale.lua + Locales/): the base locale, its keys, which language
-- is shown, and the helpers that format counts and numbers
-- ---------------------------------------------------------------------------

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

test("locale_files_load_first", function()
  -- Every other file reads ns.L, and an explicit locale choice is applied on top of
  -- whatever registered -- both need the mechanism, then the locale files, up front.
  local files = localeTools.tocFiles(root)
  assertEq(files[1], "Locale.lua", "the mechanism loads first")
  assertEq(files[2], localeTools.BASE_LOCALE, "then the base locale")
  local i = 3
  while files[i] and files[i]:find("^Locales/") do i = i + 1 end
  for j = i, #files do
    assertTrue(not files[j]:find("^Locales/"), files[j] .. " must load with the other locale files, before Core.lua")
  end
end)

test("locale_keys_defined_and_used", function()
  local ns = loadAddon({})
  local base = ns.locales.enUS
  local scan = localeTools.scanKeys(root)
  -- A computed lookup would hide its key from this scan.
  assertEq(#scan.dynamic, 0, "the string table is read only as L.KEY: " .. table.concat(scan.dynamic, "; "))
  for _, key in ipairs(sortedKeys(scan.read)) do
    assertTrue(base[key] ~= nil,
      scan.read[key] .. " reads L." .. key .. ", which " .. localeTools.BASE_LOCALE .. " never defines")
  end
  for _, key in ipairs(sortedKeys(base)) do
    assertTrue(scan.read[key], localeTools.BASE_LOCALE .. " defines " .. key .. ", which no file reads")
  end
end)

test("locale_base_values_wellformed", function()
  local ns = loadAddon({})
  local count = 0
  for key, value in pairs(ns.locales.enUS) do
    count = count + 1
    assertTrue(type(key) == "string" and key:find("^[%u][%u%d_]*$") ~= nil, "key is not UPPER_SNAKE: " .. tostring(key))
    assertTrue(type(value) == "string" and value ~= "", key .. " must be a non-empty string")
    local sig, reason, positional = localeTools.signature(value)
    assertTrue(sig, key .. ": " .. tostring(reason))
    -- The base locale is the one that runs headless, and stock Lua's string.format has
    -- no positional arguments -- those are for translations, in the game client.
    assertTrue(not positional, key .. ": the base locale uses plain placeholders only")
  end
  assertTrue(count > 100, "the base locale defines the addon's strings")
end)

test("locale_missing_key_reads_back_as_its_name", function()
  local ns = loadAddon({})
  -- A typo'd key must render as visible text, never throw inside a render...
  assertEq(ns.L.NO_SUCH_KEY, "NO_SUCH_KEY")
  assertEq(ns.L.NO_SUCH_KEY:format(3), "NO_SUCH_KEY")
  -- ...and the fallback never writes the miss into the table.
  assertEq(rawget(ns.L, "NO_SUCH_KEY"), nil)
end)

test("locale_priority_explicit_then_client_then_english", function()
  -- Priority 3: no translation for this client's language -> English.
  local ns = loadAddon({ setup = function(st) st.locale = "xxXX" end })
  assertEq(ns.GetLocaleCode(), "enUS")
  assertEq(ns.L.SCOPE_WARBAND, "Warband")

  -- Priority 2: the client's language, as soon as a translation for it registers.
  local mine = ns.NewLocale("xxXX")
  mine.SCOPE_WARBAND = "Kriegsmeute"
  assertEq(ns.GetLocaleCode(), "xxXX")
  assertEq(ns.L.SCOPE_WARBAND, "Kriegsmeute")
  assertEq(ns.L.ZONES_TITLE, "Top zones", "a key the translation leaves out stays English")
  assertEq(ns.GetScopes()[#ns.GetScopes()].name, "Kriegsmeute", "seams read the table at call time")

  -- Another language's translation is inert on this client...
  local other = ns.NewLocale("yyYY")
  other.SCOPE_WARBAND = "Bataillon"
  assertEq(ns.L.SCOPE_WARBAND, "Kriegsmeute")

  -- ...until it is chosen explicitly. Priority 1 beats the client's language.
  assertTrue(ns.SetLocale("yyYY"))
  assertEq(ns.GetLocaleCode(), "yyYY")
  assertEq(ns.L.SCOPE_WARBAND, "Bataillon")
  assertTrue(ns.SetLocale("enUS"), "English can be chosen explicitly on a translated client")
  assertEq(ns.L.SCOPE_WARBAND, "Warband")
  assertEq(ns.SetLocale("zzZZ"), false, "an unregistered code is refused")
  assertEq(ns.GetLocaleCode(), "enUS", "... and changes nothing")

  -- Clearing the choice returns to the client's language.
  assertTrue(ns.SetLocale(nil))
  assertEq(ns.GetLocaleCode(), "xxXX")
  local codes = table.concat(ns.GetLocaleCodes(), ",")
  assertTrue(codes:find("enUS", 1, true) and codes:find("xxXX,yyYY", 1, true), "registered codes, sorted: " .. codes)
end)

test("locale_codes_can_share_a_translation", function()
  local ns = loadAddon({})
  local shared = ns.NewLocale("xxXX", "yyYY")
  shared.SCOPE_WARBAND = "Banda"
  assertEq(ns.locales.xxXX, ns.locales.yyYY, "one table serves both client codes")
  assertTrue(ns.SetLocale("yyYY"))
  assertEq(ns.L.SCOPE_WARBAND, "Banda")
end)

test("locale_listeners_follow_the_active_locale", function()
  -- ns.OnLocale keeps the strings handed to the game at file load (the Key Bindings
  -- label, the New-session prompt) in step with an explicit choice applied later.
  local ns = loadAddon({})
  local seen = {}
  ns.OnLocale(function() seen[#seen + 1] = ns.L.SCOPE_WARBAND end)
  assertEq(#seen, 1, "runs once right away")
  assertEq(seen[1], "Warband")
  local other = ns.NewLocale("xxXX")
  other.SCOPE_WARBAND = "Kriegsmeute"
  assertEq(#seen, 1, "another client's translation registering changes nothing")
  ns.SetLocale("xxXX")
  assertEq(seen[2], "Kriegsmeute", "runs again when the active locale changes")
  ns.SetLocale("xxXX")
  assertEq(#seen, 2, "... and not when it stays the same")
  ns.SetLocale(nil)
  assertEq(seen[3], "Warband")
end)

test("plural_matches_the_old_inline_rule", function()
  -- The oracle is the expression the footers used before ns.Plural existed.
  local ns = loadAddon({})
  for _, n in ipairs({ 0, 1, 2, 21, 101 }) do
    assertEq(ns.Plural(n, ns.L.CASTS_ONE, ns.L.CASTS_MANY), ("%d %s"):format(n, n == 1 and "cast" or "casts"))
    assertEq(ns.Plural(n, ns.L.CATCHES_ONE, ns.L.CATCHES_MANY), ("%d %s"):format(n, n == 1 and "catch" or "catches"))
  end
end)

test("format_number_matches_the_old_ui_helper", function()
  -- Verbatim copy of UI.lua's fmtNum as it was before ns.FormatNumber replaced it.
  local function oldFmtNum(n)
    n = n or 0
    local s = tostring(math.floor(n + 0.5))
    local sign, digits = s:match("^(%-?)(%d+)$")
    if not digits then return s end
    digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return sign .. digits
  end
  local ns = loadAddon({})
  local samples = { 0, 1, 12, 999, 1000, 1234, 12345, 123456, 1234567, 1234567890,
    -1, -999, -1000, -1234567, 0.4, 0.5, 999.5, 1234.49, 1e15, 1e16 }
  for _, n in ipairs(samples) do
    assertEq(ns.FormatNumber(n), oldFmtNum(n), "n = " .. tostring(n))
  end
  for n = 0, 250000, 137 do
    assertEq(ns.FormatNumber(n), oldFmtNum(n), "n = " .. n)
  end
  assertEq(ns.FormatNumber(nil), oldFmtNum(nil), "nil counts as zero")
  assertEq(ns.FormatNumber(1234567), "1,234,567")
end)

test("format_number_uses_the_locale_separator", function()
  local ns = loadAddon({})
  local T = ns.NewLocale("xxXX")
  ns.SetLocale("xxXX")
  assertEq(ns.FormatNumber(1234567), "1,234,567", "not translated: the English separator")
  T.THOUSANDS_SEPARATOR = "."
  assertEq(ns.FormatNumber(1234567), "1.234.567")
  assertEq(ns.FormatNumber(-1234), "-1.234")
  T.THOUSANDS_SEPARATOR = "\226\128\175"  -- a multi-byte separator (narrow no-break space)
  assertEq(ns.FormatNumber(1234567), "1\226\128\175234\226\128\175567")
  T.THOUSANDS_SEPARATOR = "%"             -- a pattern-special character is taken literally
  assertEq(ns.FormatNumber(1234), "1%234")
  T.THOUSANDS_SEPARATOR = ""              -- no grouping; must not hang
  assertEq(ns.FormatNumber(1234567), "1234567")
end)

-- ---------------------------------------------------------------------------
-- A translated client. The stand-in translation is built from the base locale itself:
-- every ASCII letter becomes "#", placeholders survive in place. Any letter that still
-- shows up afterwards did not come from the string table.
-- ---------------------------------------------------------------------------

local function standIn(value)
  local parts, pos = {}, 1
  while true do
    local s, e = value:find("%%[%d%.]*%a", pos)
    parts[#parts + 1] = (value:sub(pos, (s or 0) - 1):gsub("%a", "#"))
    if not s then break end
    parts[#parts + 1] = value:sub(s, e)
    pos = e + 1
  end
  return table.concat(parts)
end

-- A loadAddon opts.locale hook that registers the stand-in under `code`, exactly where
-- a real Locales/<code>.lua would load. P (optional) receives the translated table.
local function standInLocale(code, P)
  return function(ns)
    local T = ns.NewLocale(code)
    for key, value in pairs(ns.locales.enUS) do
      T[key] = standIn(value)
      if P then P[key] = T[key] end
    end
  end
end

-- Fails when `text` still shows a letter once the brand, the color codes, and the given
-- tokens (a slash word the player typed, a stubbed value) are taken out.
local function assertNoEnglish(text, where, ...)
  local s = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("Fish & Tips", "")
  for i = 1, select("#", ...) do
    local token = select(i, ...)
    if token then s = s:gsub(token, "", 1) end
  end
  local leak = s:match("%a[%a ']*")
  if leak then
    error(where .. ': "' .. leak .. '" is displayed without going through the string table', 2)
  end
end

test("locale_translation_reaches_every_displayed_string", function()
  -- Everything the two harness-loaded files can display, under the stand-in. The other
  -- files see the table through a proxy that records which keys they ever read.
  local P, used = {}, {}
  local function hook(ns)
    standInLocale("xxXX", P)(ns)
    local real = ns.L
    ns.L = setmetatable({}, { __index = function(_, key)
      used[key] = true
      return real[key]
    end })
  end
  local function world(db)
    return loadAddon({ locale = hook, db = db, setup = function(st)
      st.locale = "xxXX"
      st.installSettingsPanel()
    end })
  end

  -- ---- seam labels and number formatting
  local ns, S = world()
  assertEq(ns.GetLocaleCode(), "xxXX")
  assertEq(ns.GetScopes()[#ns.GetScopes()].name, P.SCOPE_WARBAND)
  assertNoEnglish(P.SCOPE_WARBAND, "the Warband scope")
  assertEq(ns.FormatNumber(1234), "1,234")

  -- ---- the options panel: every label, tooltip, dropdown choice, slider value, header
  for _, c in ipairs(S.panel.controls) do
    assertNoEnglish(c.name, c.key .. " label")
    assertNoEnglish(c.tooltip, c.key .. " tooltip")
    if c.kind == "dropdown" then
      for _, o in ipairs(c.options()) do assertNoEnglish(o.label, c.key .. " choice") end
    end
    if c.sliderOptions then
      assertNoEnglish(c.sliderOptions.formatter(c.sliderOptions.min), c.key .. " slider value")
    end
  end
  assertTrue(#S.panel.headers >= 7, "section headers plus the two footer lines")
  for _, h in ipairs(S.panel.headers) do
    assertNoEnglish(h, "panel header", "test")  -- the stubbed version / donate value
  end

  -- ---- every /ft setting reply (the typed word is a command token and stays as typed)
  local function reply(msg, token)
    assertNoEnglish(slash(S, msg), "/ft " .. msg, token)
  end
  reply("cast key", "key")
  reply("session zone", "zone")
  reply("autoloot off", "off")
  reply("alerts off", "off")
  reply("alerts epic", "epic")
  reply("alerts value on", "on")
  reply("alerts value 250")
  reply("junk off", "off")
  reply("junksort off", "off")
  reply("icons off", "off")
  reply("auc off", "off")
  reply("theme classic", "classic")

  -- ---- session summaries: singular and plural nouns, without and with a gold value
  local _, S2 = world()
  cast(S2)
  catchFish(S2, 111, 1, 1)
  S2.advance(31 * 60)
  cast(S2)                       -- ends the 1-cast, 1-catch session: the plain summary
  catchFish(S2, 111, 2, 1)
  S2.advance(60)
  cast(S2)
  S2.setPrices({ [111] = 100000 })  -- 10g each
  S2.advance(31 * 60)
  cast(S2)                       -- ends the 2-cast, 2-catch session: the priced summary
  assertEq(#S2.printed, 2, "two summaries printed")
  assertEq(S2.printed[1], PREFIX .. P.CHAT_SESSION_ENDED:format(
    P.CASTS_ONE:format(1), P.CATCHES_ONE:format(1), 5, 12))
  assertEq(S2.printed[2], PREFIX .. P.CHAT_SESSION_ENDED_VALUE:format(
    P.CASTS_MANY:format(2), P.CATCHES_MANY:format(2), 6, 20, 20))
  assertNoEnglish(S2.printed[1], "session summary")
  assertNoEnglish(S2.printed[2], "priced session summary")

  -- ---- the newer-saved-data warning
  local _, S3 = world({ version = 99, chars = {} })
  assertEq(S3.printed[1], PREFIX .. P.CHAT_NEWER_DATA:format(99, 1))
  assertNoEnglish(S3.printed[1], "newer-data warning")

  -- ---- and together they read every key these files use: a key they never read is a
  -- string this test cannot vouch for. (UI.lua and Casting.lua can't load here; their
  -- keys are covered by locale_keys_defined_and_used only.)
  local scan = localeTools.scanKeys(root)
  for _, file in ipairs({ "Locale.lua", "Core.lua", "Settings.lua" }) do
    for _, key in ipairs(sortedKeys(scan.byFile[file])) do
      assertTrue(used[key], file .. " reads L." .. key .. ", which this test never displays: extend it")
    end
  end
end)

test("locale_saved_choice_applies_before_the_panel_registers", function()
  local P = {}
  local ns, S = loadAddon({
    locale = standInLocale("xxXX", P),
    setup = function(st) st.installSettingsPanel() end,  -- an enUS client
    db = { version = 1, chars = {}, settings = { locale = "xxXX" } },
  })
  assertEq(ns.GetLocaleCode(), "xxXX", "the saved choice wins over the client's language")
  assertEq(S.panel.byKey.autoLoot.name, P.OPT_AUTO_LOOT, "the panel registered in the chosen language")
  assertEq(ns.GetScopes()[#ns.GetScopes()].name, P.SCOPE_WARBAND)
  assertEq(ns.GetSettings().locale, "xxXX", "the choice stays until changed")
end)

test("locale_saved_choice_stale_or_garbage_is_dropped", function()
  local ns = loadAddon({ db = { version = 1, chars = {}, settings = { locale = "zzZZ" } } })
  assertEq(ns.GetLocaleCode(), "enUS", "an unregistered code falls back to the client, then English")
  assertEq(ns.GetSettings().locale, nil, "... and is cleared")
  assertEq(ns.L.SCOPE_WARBAND, "Warband")
  local ns2 = loadAddon({ db = { version = 1, chars = {}, settings = { locale = 42 } } })
  assertEq(ns2.GetSettings().locale, nil, "type garbage is cleared")
  assertEq(ns2.GetLocaleCode(), "enUS")
  local ns3 = loadAddon({})
  assertEq(_G.FishTipsDB.settings.locale, nil, "nothing is stored unless a choice is made")
  assertEq(ns3.GetLocaleCode(), "enUS")
end)

test("locale_slash_command", function()
  local P = {}
  local ns, S = loadAddon({ locale = standInLocale("xxXX", P) })
  local choices = table.concat(ns.GetLocaleCodes(), " | ") .. " | default"
  assertEq(slash(S, "locale"), PREFIX .. "locale: " .. choices .. "  (showing enUS, set to default)")
  assertEq(slash(S, "locale xxXX"), PREFIX .. "locale: xxXX. /reload to apply.",
    "the code matches case-insensitively and is stored in its real spelling")
  assertEq(ns.GetSettings().locale, "xxXX")
  assertEq(ns.L.SCOPE_WARBAND, "Warband", "nothing switches until the reload")
  -- The reload: the same SavedVariables, a fresh addon world.
  local ns2, S2 = loadAddon({ locale = standInLocale("xxXX"), db = deepCopy(_G.FishTipsDB) })
  assertEq(ns2.L.SCOPE_WARBAND, P.SCOPE_WARBAND, "after the reload the choice is in effect")
  assertEq(slash(S2, "locale"), PREFIX .. "locale: " .. choices .. "  (showing xxXX, set to xxXX)")
  assertEq(slash(S2, "locale klingon"), PREFIX .. "locale: no translation 'klingon'. Available: " .. choices)
  assertEq(ns2.GetSettings().locale, "xxXX", "a refused code changes nothing")
  assertEq(slash(S2, "locale enUS"), PREFIX .. "locale: enUS. /reload to apply.")
  assertEq(ns2.GetSettings().locale, "enUS", "English can be set explicitly")
  assertEq(slash(S2, "locale default"),
    PREFIX .. "locale: default (the game client's language). /reload to apply.")
  assertEq(ns2.GetSettings().locale, nil)
  local ns3 = loadAddon({ locale = standInLocale("xxXX"), db = deepCopy(_G.FishTipsDB) })
  assertEq(ns3.GetLocaleCode(), "enUS", "back to the client's language")
end)

test("stored_data_is_identical_in_every_language", function()
  -- Only display text is localized: the same outing must store identical data whatever
  -- language the text renders in.
  local english, SE = storedDataAfterOuting({})
  assertTrue(summaryLine(SE) ~= nil, "the English run printed the English summary")

  local P = {}
  local translated, ST = storedDataAfterOuting({
    locale = standInLocale("xxXX", P),
    setup = function(st) st.locale = "xxXX" end,
  })
  assertTrue(summaryLine(ST) == nil, "the translated run printed no English summary")
  assertTrue(summaryLine(ST, P.CHAT_SESSION_ENDED:match("^[^%%]+")) ~= nil, "... it printed the translated one")
  assertTrue(deepEqual(translated, english), "a translation changes nothing that is stored")

  local chosen = storedDataAfterOuting({
    locale = standInLocale("xxXX"),
    db = { version = 1, chars = {}, settings = { locale = "xxXX" } },
  })
  assertEq(chosen.settings.locale, "xxXX")
  chosen.settings.locale = nil  -- the saved choice itself is the only difference
  assertTrue(deepEqual(chosen, english), "an explicit choice changes nothing else that is stored")
end)

-- ---------------------------------------------------------------------------
-- Translation files
-- ---------------------------------------------------------------------------

test("locale_translation_check_catches_mistakes", function()
  local check = localeTools.checkTranslation
  local base = { BAGS = "bags %d", ALT = "%s %d", PLAIN = "plain", DELAY = "%.2fs" }
  -- Reworded, reordered through the positional form, a changed precision, and the
  -- game's plural escape: all fine.
  assertEq(#check(base, {
    BAGS = "%d |4Tasche:Taschen;",
    ALT = "%2$d \195\151 %1$s",
    PLAIN = "schlicht",
    DELAY = "%.1f Sek.",
  }), 0)
  assertEq(check(base, { BAGZ = "Taschen %d" })[1], "BAGZ: not a key of the base locale")
  assertEq(#check(base, { BAGS = "Taschen" }), 1, "a dropped placeholder")
  assertEq(#check(base, { BAGS = "Taschen %s" }), 1, "a placeholder of the wrong kind")
  assertEq(#check(base, { ALT = "%d %s" }), 1, "reordered without the positional form")
  assertEq(#check(base, { ALT = "%1$s %1$s" }), 1, "an argument used twice, one lost")
  assertEq(#check(base, { ALT = "%2$d %s" }), 1, "positional and plain placeholders mixed")
  assertEq(#check(base, { PLAIN = "100% schlicht" }), 1, "a stray percent sign")
  assertEq(#check(base, { PLAIN = "100%% schlicht" }), 0, "an escaped percent sign is fine")
  assertEq(#check(base, { PLAIN = "" }), 1, "an empty value")
  assertEq(#check(base, { PLAIN = true }), 1, "a non-string value")
end)

test("locale_translation_files_valid", function()
  -- Every Locales/xxXX.lua the TOC lists besides the base: it registers the client
  -- language its file name promises and assigns only base keys, placeholders intact.
  -- (No translation ships yet, so today this loop has nothing to visit -- the first one
  -- added to the TOC is checked from then on.)
  for _, file in ipairs(localeTools.tocFiles(root)) do
    local code = file:match("^Locales/(%w+)%.lua$")
    if code and file ~= localeTools.BASE_LOCALE then
      assertTrue(localeTools.LOCALE_CODES[code], file .. ": '" .. code .. "' is not a client language code")
      stubs.install()
      local ns = {}
      assert(loadfile(root .. "Locale.lua"))("FishTips", ns)
      assert(loadfile(root .. localeTools.BASE_LOCALE))("FishTips", ns)
      local base = deepCopy(ns.locales.enUS)
      assert(loadfile(root .. file))("FishTips", ns)
      local overlay = ns.locales[code]
      assertTrue(type(overlay) == "table" and next(overlay) ~= nil,
        file .. " must register '" .. code .. "' and translate something")
      assertTrue(overlay ~= ns.locales.enUS and deepEqual(ns.locales.enUS, base),
        file .. " must not write into the base locale")
      for registered in pairs(ns.locales) do
        assertTrue(localeTools.LOCALE_CODES[registered],
          file .. " registers '" .. tostring(registered) .. "', which is not a client language code")
      end
      assertEq(table.concat(localeTools.checkTranslation(base, overlay), " | "), "", file)
    end
  end
end)

-- ---------------------------------------------------------------------------
-- Runner
-- ---------------------------------------------------------------------------
local failed = 0
for _, t in ipairs(tests) do
  local ok, err = xpcall(t.fn, debug.traceback)
  if ok then
    realPrint("PASS  " .. t.name)
  else
    failed = failed + 1
    realPrint("FAIL  " .. t.name .. "\n" .. tostring(err))
  end
end
realPrint(("-- %d/%d passed"):format(#tests - failed, #tests))
if failed > 0 then os.exit(1) end
