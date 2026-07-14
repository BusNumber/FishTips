-- tests/wow_stubs.lua -- minimal WoW API stubs for the LuaJIT test harness.
-- Covers only what Core.lua + Settings.lua touch at load and during the tested flows;
-- UI.lua and Casting.lua are never loaded here (frame-heavy presentation and
-- secure-binding code are verifiable only in the game client -- see CONTRIBUTING.md).
--
-- Usage: local stubs = dofile("tests/wow_stubs.lua"); stubs.install(); ...
-- install() resets every knob, so each test starts from a clean world.

local M = {}

-- Mutable knobs. Reset by install().
local function resetState()
  M.now = 1000            -- GetTime clock (uptime; does NOT survive a simulated reload)
  M.epoch = 1720000000    -- time() clock (wall clock; carried across a reload via opts.setup)
  M.timers = {}           -- pending C_Timer.After callbacks { at=, fn=, done= }
  M.charName = "Tester"
  M.realm = "TestRealm"
  M.zone = "Zone1"
  M.sub = "SubA"
  M.mapID = 1500
  M.isFishingLoot = false
  M.spellNames = { [7620] = "Fishing", [131474] = "Fishing", [131476] = "Fishing" }
  M.lootSlots = {}
  M.lootLinkToItem = {}
  M.lootSlotCalls = 0     -- number of LootSlot() calls since install/setLoot
  M.printed = {}          -- everything the addon print()ed
  M.frames = {}           -- every mock frame CreateFrame returned
end

function M.setTime(t) M.now = t end

-- Advance both clocks, then run any C_Timer callbacks that came due (a callback may
-- schedule more, so loop until quiet) -- models the game's timer wheel.
function M.advance(dt)
  M.now = M.now + dt
  M.epoch = M.epoch + dt
  local ran = true
  while ran do
    ran = false
    for i = 1, #M.timers do
      local t = M.timers[i]
      if t and not t.done and t.at <= M.now then
        t.done = true
        ran = true
        t.fn()
      end
    end
  end
end

-- Loot-window model: slots = array of { itemID=, name=, quantity=, quality=, link= }.
-- link = false models a money slot (GetLootSlotLink returns nil for it).
function M.setLoot(slots)
  M.lootSlots = {}
  M.lootLinkToItem = {}
  M.lootSlotCalls = 0
  for i, s in ipairs(slots) do
    local slot = {
      link = (s.link == false) and nil or (s.link or ("item:" .. tostring(s.itemID))),
      name = s.name or ("Item" .. tostring(s.itemID)),
      quantity = s.quantity or 1,
      quality = s.quality or 1,
    }
    if slot.link and s.itemID then M.lootLinkToItem[slot.link] = s.itemID end
    M.lootSlots[i] = slot
  end
end

-- Fire an event into every mock frame registered for it (the harness's event bus).
function M.fire(event, ...)
  for _, f in ipairs(M.frames) do
    if f.events[event] and f.scripts.OnEvent then
      f.scripts.OnEvent(f, event, ...)
    end
  end
end

function M.install()
  resetState()

  _G.GetTime = function() return M.now end
  _G.time = function() return M.epoch end
  _G.C_Timer = {
    After = function(delay, fn)
      M.timers[#M.timers + 1] = { at = M.now + delay, fn = fn }
    end,
  }

  -- Mock frame: captures RegisterEvent + SetScript so M.fire can drive OnEvent.
  _G.CreateFrame = function()
    local f = { events = {}, scripts = {} }
    function f:RegisterEvent(e) self.events[e] = true end
    function f:UnregisterEvent(e) self.events[e] = nil end
    function f:SetScript(k, fn) self.scripts[k] = fn end
    M.frames[#M.frames + 1] = f
    return f
  end

  _G.UnitName = function() return M.charName end
  _G.GetNormalizedRealmName = function() return M.realm end
  _G.GetRealZoneText = function() return M.zone end
  _G.GetSubZoneText = function() return M.sub end
  _G.UNKNOWN = "Unknown"

  _G.C_Map = { GetBestMapForUnit = function() return M.mapID end }

  _G.C_Spell = {
    GetSpellName = function(id) return M.spellNames[id] end,
    GetSpellInfo = function(id)
      local n = M.spellNames[id]
      if n then return { name = n } end
      return nil
    end,
  }
  _G.GetSpellInfo = function(id) return M.spellNames[id] end

  _G.GetNumLootItems = function() return #M.lootSlots end
  _G.GetLootSlotLink = function(i)
    local s = M.lootSlots[i]
    return s and s.link or nil
  end
  _G.GetLootSlotInfo = function(i)
    local s = M.lootSlots[i]
    if not s then return nil end
    return "tex", s.name, s.quantity, nil, s.quality
  end
  _G.GetItemInfoInstant = function(link) return M.lootLinkToItem[link] end
  _G.LootSlot = function(i)
    M.lootSlotCalls = M.lootSlotCalls + 1
    table.remove(M.lootSlots, i)  -- models the client re-indexing the loot list
  end
  _G.IsFishingLoot = function() return M.isFishingLoot end

  _G.C_AddOns = { GetAddOnMetadata = function() return "test" end }
  _G.SlashCmdList = {}
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    M.printed[#M.printed + 1] = table.concat(parts, " ")
  end

  _G.FishTipsDB = nil
end

return M
