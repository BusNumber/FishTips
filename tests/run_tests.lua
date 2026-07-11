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
local ADDON_FILES = { "Locale.lua", "Core.lua", "Settings.lua" }  -- TOC order (UI/Casting are in-game-only)

local function loadAddon(opts)
  opts = opts or {}
  stubs.install()
  if opts.setup then opts.setup(stubs) end
  _G.FishTipsDB = opts.db
  local ns = {}
  for _, file in ipairs(ADDON_FILES) do
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

test("locale_table_passthrough", function()
  local ns = loadAddon({})
  assertEq(ns.L["Warband"], "Warband", "missing key falls back to itself")
  ns.L["Warband"] = "Kriegsmeute"
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
