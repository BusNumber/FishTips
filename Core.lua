local addonName, ns = ...

-- Core.lua -- data layer: SavedVariables DB, character identity, current-location
-- resolution, catch tracking + fishing-only auto-loot, and the read-only `ns.Get*` seams
-- the UI renders from. A demo provider (ns.demo) backs the same seams so the UI can be
-- worked on without fishing. The UI never reads FishTipsDB directly.

local DB_VERSION = 1

-- ---------------------------------------------------------------------------
-- Refresh notification (data layer -> presentation)
-- ---------------------------------------------------------------------------
local refreshers = {}

function ns.RegisterRefresh(fn)
  refreshers[#refreshers + 1] = fn
end

function ns.FireRefresh()
  for i = 1, #refreshers do
    refreshers[i]()
  end
end

-- Fishing-start notification -- used by the UI to auto-open the window when the player
-- begins fishing. Separate from FireRefresh because that one only repaints an already-open
-- window; this one must be able to *show* it.
local fishingStarters = {}

function ns.RegisterFishingStart(fn)
  fishingStarters[#fishingStarters + 1] = fn
end

function ns.FireFishingStart()
  for i = 1, #fishingStarters do
    fishingStarters[i]()
  end
end

-- ---------------------------------------------------------------------------
-- Character identity -- resolved lazily; the normalized realm is unreliable at
-- ADDON_LOADED, so we wait until PLAYER_LOGIN / first use (PEW-safe).
-- ---------------------------------------------------------------------------
local charKey
function ns.CharKey()
  if not charKey then
    local name = UnitName("player")
    local realm = GetNormalizedRealmName()
    if name and realm and realm ~= "" then
      charKey = name .. "-" .. realm
    end
  end
  return charKey
end

-- The scope that owns the live session. Session data is inherently the current
-- character; under demo we point at the demo's primary character so the Session view
-- has data to show.
function ns.GetSessionScope()
  if ns.demoOn then return ns.demo.currentKey end
  return ns.CharKey()
end

-- ---------------------------------------------------------------------------
-- Session bookkeeping (in-memory; resets on login/reload)
-- ---------------------------------------------------------------------------
ns.sessionStart = nil
local realSession = {}  -- [charKey] = { casts = n, zones = {...} }

function ns.SessionElapsed()
  if ns.demoOn then
    return ns.demo and ns.demo.sessionElapsed or 0
  end
  if ns.sessionStart then
    return GetTime() - ns.sessionStart
  end
  return 0
end

-- ---------------------------------------------------------------------------
-- Demo toggle
-- ---------------------------------------------------------------------------
function ns.SetDemo(on)
  ns.demoOn = on and true or false
  ns.FireRefresh()
end

function ns.IsDemo()
  return ns.demoOn and true or false
end

-- ---------------------------------------------------------------------------
-- Active data source -- demo set, or the real per-character store
-- ---------------------------------------------------------------------------
local function realChars()
  local out = {}
  local db = ns.db
  if db and db.chars then
    for key, c in pairs(db.chars) do
      out[key] = {
        display = key:match("^(.-)%-") or key,
        lifetime = c.lifetime,
        session = realSession[key],
      }
    end
  end
  local me = ns.CharKey()
  if me and not out[me] then
    local life = db and db.chars and db.chars[me] and db.chars[me].lifetime
    out[me] = {
      display = me:match("^(.-)%-") or me,
      lifetime = life or { casts = 0, zones = {} },
      session = realSession[me],
    }
  end
  return out
end

local function activeChars()
  if ns.demoOn then return ns.demo.chars end
  return realChars()
end

local function bucketOf(c, mode)
  if mode == "session" then return c.session end
  return c.lifetime
end

-- Display-time filter: when the includeJunk setting is off, gray (quality-0) catches are
-- hidden from the read seams (list + totals) but still recorded. Settings may be nil before
-- InitSettings -> treat as "show everything".
local function junkHidden()
  local s = ns.GetSettings and ns.GetSettings()
  return s ~= nil and s.includeJunk == false
end

local function sumItems(items)
  local n = 0
  if items then
    local hide = junkHidden()
    for _, it in pairs(items) do
      if not (hide and it.quality == 0) then n = n + (it.count or 0) end
    end
  end
  return n
end

local function bucketCatches(bucket)
  local n = 0
  if bucket and bucket.zones then
    for _, z in pairs(bucket.zones) do
      if z.subs then
        for _, s in pairs(z.subs) do n = n + sumItems(s.items) end
      end
    end
  end
  return n
end

local function scopeChars(scope)
  local chars = activeChars()
  if scope == "account" then return chars end
  local c = chars[scope]
  if c then return { [scope] = c } end
  return {}
end

-- ---------------------------------------------------------------------------
-- Read-only seams (UI talks only to these). The account rollup is derived here,
-- so the invariant "account total = sum of characters" can't be broken by a
-- rendering path.
-- ---------------------------------------------------------------------------
function ns.GetCurrentLocation()
  if ns.demoOn then
    return ns.demo.location
  end
  local zone = GetRealZoneText()
  if not zone or zone == "" then zone = UNKNOWN end
  local sub = GetSubZoneText() or ""
  local mapID = C_Map and C_Map.GetBestMapForUnit("player") or nil
  return { zone = zone, subZone = sub, isSpecialPool = false, mapID = mapID }
end

function ns.GetScopes()
  local list = {}
  for key, c in pairs(activeChars()) do
    list[#list + 1] = { key = key, name = c.display or key }
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  list[#list + 1] = { key = "account", name = "Warband" }
  return list
end

function ns.GetTotals(scope, mode)
  local casts, catches = 0, 0
  for _, c in pairs(scopeChars(scope)) do
    local b = bucketOf(c, mode)
    if b then
      casts = casts + (b.casts or 0)
      catches = catches + bucketCatches(b)
    end
  end
  local elapsed = ns.SessionElapsed()
  local rate
  if mode == "session" and elapsed and elapsed > 0 then
    rate = math.floor(catches / (elapsed / 3600) + 0.5)
  end
  return { casts = casts, catches = catches, ratePerHour = rate, elapsed = elapsed }
end

function ns.GetZoneTotals(scope, mode)
  local acc = {}
  for _, c in pairs(scopeChars(scope)) do
    local b = bucketOf(c, mode)
    if b and b.zones then
      for zoneName, z in pairs(b.zones) do
        local n = 0
        if z.subs then
          for _, s in pairs(z.subs) do n = n + sumItems(s.items) end
        end
        acc[zoneName] = (acc[zoneName] or 0) + n
      end
    end
  end
  local list = {}
  for zoneName, n in pairs(acc) do
    list[#list + 1] = { zone = zoneName, catches = n }
  end
  table.sort(list, function(a, b) return a.catches > b.catches end)
  return list
end

local function resolveItem(m)
  if not m.name and m.link then
    m.name = m.link:match("%[(.-)%]")
  end
  if not m.name then m.name = "item:" .. tostring(m.itemID) end
  if not m.quality then m.quality = 1 end
  return m
end

function ns.GetLocationItems(scope, mode, zone, sub)
  local merged = {}
  local hide = junkHidden()
  for _, c in pairs(scopeChars(scope)) do
    local b = bucketOf(c, mode)
    local z = b and b.zones and b.zones[zone]
    local s = z and z.subs and z.subs[sub]
    if s and s.items then
      for itemID, it in pairs(s.items) do
        if not (hide and it.quality == 0) then
          local m = merged[itemID]
          if not m then
            m = { itemID = itemID, count = 0, name = it.name, quality = it.quality, link = it.link }
            merged[itemID] = m
          end
          m.count = m.count + (it.count or 0)
        end
      end
    end
  end
  local list = {}
  for _, m in pairs(merged) do
    list[#list + 1] = resolveItem(m)
  end
  table.sort(list, function(a, b) return a.count > b.count end)
  return list
end

-- ---------------------------------------------------------------------------
-- Pricing seam (optional Auctionator integration). Display-only: prices are
-- never recorded -- they're read live from Auctionator's public v1 API and shown
-- for the current session. All Auctionator access lives here, behind these seams,
-- so the UI never touches another addon directly.
-- ---------------------------------------------------------------------------
local AUC_CALLER = addonName  -- non-empty callerID the API requires; just our name

-- True only when the user opted in AND Auctionator's API is actually present. Single
-- source of truth for "show prices" -- both Core and the UI gate on this.
function ns.PricingActive()
  local s = ns.GetSettings and ns.GetSettings()
  if not (s and s.auctionatorPrices) then return false end
  return Auctionator ~= nil and Auctionator.API ~= nil and Auctionator.API.v1 ~= nil
    and Auctionator.API.v1.GetAuctionPriceByItemID ~= nil
end

-- Unit market price for one item, in COPPER, or nil when pricing is off or Auctionator
-- has no scanned data for it. itemID is coerced to a number (the API errors otherwise);
-- the call is pcall-wrapped since it's a third-party entry point that can error().
function ns.GetItemPrice(itemID)
  if not ns.PricingActive() then return nil end
  itemID = tonumber(itemID)
  if not itemID then return nil end
  local ok, price = pcall(Auctionator.API.v1.GetAuctionPriceByItemID, AUC_CALLER, itemID)
  if ok then return price end
  return nil
end

-- Total value of the current session's catches, in COPPER, or nil if pricing is off.
-- Sums count * unit price across every zone/sub in the session bucket, skipping items
-- with no price (they contribute 0, not "?"), and honoring the includeJunk filter so
-- the total stays consistent with the visible list.
function ns.GetSessionValue()
  if not ns.PricingActive() then return nil end
  local hide = junkHidden()
  local total = 0
  for _, c in pairs(scopeChars(ns.GetSessionScope())) do
    local b = c.session
    if b and b.zones then
      for _, z in pairs(b.zones) do
        if z.subs then
          for _, s in pairs(z.subs) do
            if s.items then
              for itemID, it in pairs(s.items) do
                if not (hide and it.quality == 0) then
                  local unit = ns.GetItemPrice(itemID)
                  if unit then total = total + unit * (it.count or 0) end
                end
              end
            end
          end
        end
      end
    end
  end
  return total
end

-- ---------------------------------------------------------------------------
-- Demo provider -- the mock dataset from the UI concepts. Dev-gated by
-- `/fishtips demo`; clearly separated from the real DB and never written to it.
-- Two characters so the account rollup (and scope dropdown) is exercised; itemIDs
-- are shared across characters so account-merge sums the same fish.
-- Keyed by REAL Midnight (12.0) fishing itemIDs so the Auctionator price overlay
-- shows live AH prices in demo mode. Qualities confirmed in-game: Lynxfish /
-- Arcane Wyrmfish / Sin'dorei Swarmer common, Shimmersiren / Tender Lumifin uncommon,
-- Eversong Trout rare. The gray junk entry uses a placeholder id (vendor trash has no
-- AH price -> renders "?") and only exists to exercise the includeJunk filter.
-- ---------------------------------------------------------------------------
ns.demo = {
  sessionElapsed = 900,
  currentKey = "Nariel-Silvermoon",
  location = { zone = "Voidstorm", subZone = "Oceanic Vortex", isSpecialPool = true, mapID = 2369 },
  chars = {
    ["Nariel-Silvermoon"] = {
      display = "Nariel",
      lifetime = {
        casts = 4127,
        zones = {
          ["Voidstorm"] = { subs = { ["Oceanic Vortex"] = { items = {
            [238378] = { name = "Shimmersiren",      quality = 2, count = 421 },
            [238366] = { name = "Lynxfish",          quality = 1, count = 388 },
            [238371] = { name = "Arcane Wyrmfish",   quality = 1, count = 305 },
            [238365] = { name = "Sin'dorei Swarmer", quality = 1, count = 142 },
            [238374] = { name = "Tender Lumifin",    quality = 2, count = 64 },
            [238383] = { name = "Eversong Trout",    quality = 3, count = 41 },
          } } } },
          ["Eversong Woods"] = { subs = { ["Elrendar River"] = { items = {
            [238366] = { name = "Lynxfish",            quality = 1, count = 1208 },
            [238371] = { name = "Arcane Wyrmfish",     quality = 1, count = 742 },
            [238374] = { name = "Tender Lumifin",      quality = 2, count = 96 },
            [990001] = { name = "Tangled Fishing Line", quality = 0, count = 64 },
            [238383] = { name = "Eversong Trout",      quality = 3, count = 38 },
          } } } },
          ["Silvermoon City"] = { subs = { ["Ruby Quarter"] = { items = {
            [238365] = { name = "Sin'dorei Swarmer", quality = 1, count = 884 },
          } } } },
        },
      },
      session = {
        casts = 78,
        zones = {
          ["Voidstorm"] = { subs = { ["Oceanic Vortex"] = { items = {
            [238366] = { name = "Lynxfish",          quality = 1, count = 31 },
            [238378] = { name = "Shimmersiren",      quality = 2, count = 23 },
            [238371] = { name = "Arcane Wyrmfish",   quality = 1, count = 19 },
            [238365] = { name = "Sin'dorei Swarmer", quality = 1, count = 12 },
            [238374] = { name = "Tender Lumifin",    quality = 2, count = 5 },
            [238383] = { name = "Eversong Trout",    quality = 3, count = 2 },
          } } } },
        },
      },
    },
    ["Thalric-Silvermoon"] = {
      display = "Thalric",
      lifetime = {
        casts = 470,
        zones = {
          ["Voidstorm"] = { subs = { ["Oceanic Vortex"] = { items = {
            [238378] = { name = "Shimmersiren", quality = 2, count = 140 },
            [238366] = { name = "Lynxfish",     quality = 1, count = 96 },
          } } } },
          ["Isle of Quel'Danas"] = { subs = { ["Sun's Reach Harbor"] = { items = {
            [238374] = { name = "Tender Lumifin", quality = 2, count = 210 },
            [238366] = { name = "Lynxfish",       quality = 1, count = 47 },
          } } } },
        },
      },
      session = nil,
    },
  },
}

-- ---------------------------------------------------------------------------
-- Fishing spell identity + catch write-path
-- ---------------------------------------------------------------------------
-- Fishing fires TWO spells on a real cast (confirmed in-game via UNIT_SPELLCAST_SUCCEEDED):
-- 131476 is the spell the player actively casts; it triggers 131474 (the channel/effect). So we
-- CAST 131476 (the directly-castable one -- CastSpellByID(131474) silently no-ops), and DETECT on
-- either id (or the shared name "Fishing", for pole-override variants).
local FISHING_SPELL_ID = 131476    -- castable; Casting.lua casts this via CastSpellByID
local FISHING_CHANNEL_ID = 131474  -- triggered channel; also matched for detection
ns.FishingSpellID = FISHING_SPELL_ID

local fishingName
function ns.FishingSpellName()
  if not fishingName then
    if C_Spell and C_Spell.GetSpellInfo then
      local info = C_Spell.GetSpellInfo(FISHING_SPELL_ID)
      fishingName = info and info.name
    elseif GetSpellInfo then
      fishingName = GetSpellInfo(FISHING_SPELL_ID)
    end
    fishingName = fishingName or "Fishing"
  end
  return fishingName
end

local function spellNameByID(spellID)
  if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(spellID) end
  if GetSpellInfo then return (GetSpellInfo(spellID)) end
  return nil
end

local function isFishingSpell(spellID)
  if not spellID then return false end
  if spellID == FISHING_SPELL_ID or spellID == FISHING_CHANNEL_ID then return true end
  local name = spellNameByID(spellID)
  return name ~= nil and name == ns.FishingSpellName()
end

-- Always the *real* location (GetCurrentLocation is demo-aware; recording never is).
local function currentZoneSub()
  local zone = GetRealZoneText()
  if not zone or zone == "" then zone = UNKNOWN end
  return zone, (GetSubZoneText() or "")
end

local function bucketSub(bucket, zone, sub)
  bucket.zones = bucket.zones or {}
  local z = bucket.zones[zone]
  if not z then z = { subs = {} }; bucket.zones[zone] = z end
  z.subs = z.subs or {}
  local s = z.subs[sub]
  if not s then s = { items = {} }; z.subs[sub] = s end
  s.items = s.items or {}
  return s
end

-- Record one fished item into a single bucket (lifetime or session). Keyed by itemID, so
-- the item is always referenceable programmatically; name/quality/link are stored for lazy
-- display and backfilled if an earlier record lacked them.
local function recordInto(bucket, zone, sub, itemID, count, name, quality, link)
  local s = bucketSub(bucket, zone, sub)
  local it = s.items[itemID]
  if not it then
    it = { count = 0, name = name, quality = quality, link = link }
    s.items[itemID] = it
  end
  it.count = it.count + count
  if it.name == nil then it.name = name end
  if it.quality == nil then it.quality = quality end
  if it.link == nil then it.link = link end
end

local function lifetimeOf(key)
  local db = ns.db
  if not db then return nil end
  db.chars = db.chars or {}
  local c = db.chars[key]
  if not c then c = {}; db.chars[key] = c end
  c.lifetime = c.lifetime or { casts = 0, zones = {} }
  return c.lifetime
end

local function sessionOf(key)
  local sess = realSession[key]
  if not sess then sess = { casts = 0, zones = {} }; realSession[key] = sess end
  return sess
end

function ns.RecordCast()
  local key = ns.CharKey()
  if not key then return end
  local life = lifetimeOf(key)
  if life then life.casts = (life.casts or 0) + 1 end
  local sess = sessionOf(key)
  sess.casts = (sess.casts or 0) + 1
  ns.FireRefresh()
end

-- Reset the live session for the current character: drop the in-memory session store and
-- restart the elapsed clock, so the Session view reads as if fishing had just begun. The
-- persisted lifetime history is never touched. (Under demo the Session view is backed by the
-- fixed mock dataset, so this has no visible effect there.)
function ns.ResetSession()
  local key = ns.CharKey()
  if key then realSession[key] = nil end
  ns.sessionStart = GetTime()
  ns.FireRefresh()
end

function ns.RecordCatch(itemID, count, name, quality, link)
  if not itemID then return end
  local key = ns.CharKey()
  if not key then return end
  count = count or 1
  local zone, sub = currentZoneSub()
  local life = lifetimeOf(key)
  if life then recordInto(life, zone, sub, itemID, count, name, quality, link) end
  recordInto(sessionOf(key), zone, sub, itemID, count, name, quality, link)
  ns.FireRefresh()
end

-- Read every item slot of a fishing loot window into the tracker and, when the autoLoot
-- setting is on, grab the loot too. Gated to fishing so mob / chest / herb loot is never
-- read or looted. We iterate in REVERSE because LootSlot() re-indexes the loot list (a
-- forward loop would skip slots), and we read each slot's info BEFORE looting it (a looted
-- slot's link/info clears). Looting is an insecure-callable action here -- the bobber click
-- is the player's hardware event -- so no secure button is needed.
local function handleLootOpened()
  if not (ns.fishingActive or (ns.lastFishing and GetTime() - ns.lastFishing <= 1.0)) then
    return
  end
  local s = ns.GetSettings and ns.GetSettings()
  local autoLoot = (not s) or s.autoLoot ~= false  -- default-on; nil settings => default behavior
  local n = GetNumLootItems and GetNumLootItems() or 0
  for i = n, 1, -1 do
    local link = GetLootSlotLink(i)  -- nil for money slots
    if link then
      local _, name, quantity, _, quality = GetLootSlotInfo(i)
      local itemID = GetItemInfoInstant(link)  -- nil for currency -> not tracked
      if itemID then
        ns.RecordCatch(itemID, quantity or 1, name, quality, link)
      end
    end
    if autoLoot then LootSlot(i) end  -- grabs item, money, and currency slots alike
  end
end

-- ---------------------------------------------------------------------------
-- DB init + events
-- ---------------------------------------------------------------------------
local function migrate(db)
  if db.version == nil then db.version = DB_VERSION end
  -- Future migrations preserve the catch history (never reset):
  -- while db.version < DB_VERSION do ... db.version = db.version + 1 end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("ZONE_CHANGED")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("ZONE_CHANGED_INDOORS")
f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
f:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")  -- dev diagnostic (/ft castdebug) only
f:RegisterEvent("UNIT_SPELLCAST_FAILED")     -- dev diagnostic (/ft castdebug) only
f:RegisterEvent("LOOT_OPENED")
f:SetScript("OnEvent", function(_, event, arg1, _, arg3)  -- arg3 = spellID (spellcast events)
  if event == "ADDON_LOADED" then
    if arg1 == addonName then
      FishTipsDB = FishTipsDB or {}
      local db = FishTipsDB
      migrate(db)
      db.chars = db.chars or {}
      db.addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata(addonName, "Version") or nil
      ns.db = db
      if ns.InitSettings then ns.InitSettings(db) end
    end
  elseif event == "PLAYER_LOGIN" then
    ns.sessionStart = GetTime()
    ns.CharKey()
  elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
    if arg1 == "player" then
      if ns.castDebug then  -- logs the REAL fishing spellID (manual cast) + whether we matched it
        print(("|cffffd36eFish & Tips|r: CHANNEL_START id=%s name=%s match=%s"):format(
          tostring(arg3), tostring(spellNameByID(arg3)), tostring(isFishingSpell(arg3))))
      end
      if isFishingSpell(arg3) then  -- arg3 = spellID
        ns.fishingActive = true
        ns.lastFishing = GetTime()
        ns.RecordCast()
        ns.FireFishingStart()
      end
    end
  elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
    if arg1 == "player" and isFishingSpell(arg3) then
      ns.fishingActive = false
      ns.lastFishing = GetTime()
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_FAILED" then
    if arg1 == "player" and ns.castDebug then  -- dev probe: did our cast even reach the server?
      print(("|cffffd36eFish & Tips|r: %s id=%s name=%s"):format(
        event, tostring(arg3), tostring(spellNameByID(arg3))))
    end
  elseif event == "LOOT_OPENED" then
    handleLootOpened()
  else
    ns.FireRefresh()
  end
end)
