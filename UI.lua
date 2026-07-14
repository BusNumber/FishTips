local _, ns = ...

-- UI.lua -- presentation only. Reads through the ns.Get* seams; never touches the DB.
-- One window with shared chrome (drag/scope/mode/close/collapse) and a themed body that
-- is rebuilt on theme change. Three themes share two body layouts: "classic" (inline hero
-- + footer) and "tiles" (location header + per-location list + top-zones chart + footer stat
-- bar, used by modern + blend). Item rows show the quality-colored name over a thin
-- frequency bar. A compact strip and a custom minimap button round out the surface.

local UI = {}
ns.UI = UI

local L = ns.L  -- user-facing strings go through the locale table (English keys)

-- Auto-open/auto-hide ownership: UI.autoShown is true while the visible surface was
-- shown by the auto-open path and untouched since. Any player interaction -- manual
-- toggle, a drag, any control click -- promotes the surface to player-owned, and
-- auto-hide (the session-pause subscriber at the bottom) then leaves it alone.
local function markOwned() UI.autoShown = false end

local WIN_W = 340
local PAD = 12
local INNER = WIN_W - 2 * PAD

-- Theme palettes. Colors are 0-1 RGB(A). accentText is the readable on-accent text color.
local PALETTES = {
  classic = {
    bg = { 0.051, 0.059, 0.086, 0.97 },
    border = { 0.769, 0.643, 0.384, 0.45 },
    accent = { 1.0, 0.808, 0.420 },
    accentText = { 1.0, 0.808, 0.420 },
    title = { 1.0, 0.808, 0.420 },
    textPrimary = { 0.914, 0.906, 0.878 },
    textSecondary = { 0.541, 0.529, 0.494 },
  },
  modern = {
    bg = { 0.043, 0.047, 0.067, 0.96 },
    border = { 1.0, 1.0, 1.0, 0.10 },
    accent = { 0.608, 0.529, 0.961 },
    accentText = { 0.804, 0.737, 1.0 },
    title = { 0.949, 0.945, 0.969 },
    textPrimary = { 0.906, 0.898, 0.937 },
    textSecondary = { 0.490, 0.482, 0.533 },
  },
  blend = {
    bg = { 0.051, 0.059, 0.086, 0.97 },
    border = { 0.769, 0.643, 0.384, 0.45 },
    accent = { 1.0, 0.808, 0.420 },
    accentText = { 1.0, 0.851, 0.541 },
    title = { 1.0, 0.808, 0.420 },
    textPrimary = { 0.914, 0.906, 0.878 },
    textSecondary = { 0.541, 0.529, 0.494 },
  },
}

local THEME_LAYOUT = { classic = "classic", modern = "tiles", blend = "tiles" }

-- ---------------------------------------------------------------------------
-- Primitive helpers
-- ---------------------------------------------------------------------------
local function setTex(tex, c)
  tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
end

local function MakeTex(parent, c, layer)
  local t = parent:CreateTexture(nil, layer or "BACKGROUND")
  setTex(t, c)
  return t
end

local function MakeFS(parent, size, color, flags)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(STANDARD_TEXT_FONT, size, flags or "")
  local c = color or { 1, 1, 1 }
  fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
  return fs
end

local function MakeBorder(frame, c)
  local edges = {}
  for i = 1, 4 do edges[i] = MakeTex(frame, c, "BORDER") end
  edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(1)
  edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
  edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(1)
  edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)
  return edges
end

local function recolorBorder(edges, c)
  for i = 1, #edges do setTex(edges[i], c) end
end

-- ---------------------------------------------------------------------------
-- Widget pools for the themed body. WoW never garbage-collects Frames / Textures /
-- FontStrings, so the old destroy-and-recreate body (Hide + SetParent(nil)) leaked
-- every widget it ever made. The body content is now drawn from these pools:
-- RebuildBody releases everything, the builders re-acquire, and a whole fishing
-- session reuses the same few dozen widgets.
--
-- Manual pools rather than Blizzard's CreateFramePool: that fixes the parent at pool
-- construction, but body widgets re-parent every pass (a texture can sit on the body
-- one build and inside a row the next), so acquire re-parents instead.
-- ---------------------------------------------------------------------------
local function newPool(create)
  local free, active = {}, {}
  return {
    Acquire = function(parent)
      local w = table.remove(free) or create()
      w:SetParent(parent)
      w:Show()
      active[#active + 1] = w
      return w
    end,
    ReleaseAll = function()
      for i = #active, 1, -1 do
        local w = active[i]
        w:Hide()
        w:ClearAllPoints()
        free[#free + 1] = w
        active[i] = nil
      end
    end,
  }
end

local framePool = newPool(function() return CreateFrame("Frame", nil, UIParent) end)
local texPool   = newPool(function() return UIParent:CreateTexture(nil, "BACKGROUND") end)
local fsPool    = newPool(function() return UIParent:CreateFontString(nil, "OVERLAY") end)

local function releaseBodyWidgets()
  framePool.ReleaseAll(); texPool.ReleaseAll(); fsPool.ReleaseAll()
end

-- Pooled acquire wrappers mirroring CreateFrame / MakeTex / MakeFS / MakeBorder for the
-- body builders. Every acquire re-sets the state a previous use could have left behind:
-- draw layer + color for textures; font, color, JustifyH and auto-sizing for
-- fontstrings. The SetSize(0, 0) reset is load-bearing -- it restores auto-sizing after
-- a width-constrained use (the zone chart's SetWidth would otherwise leak into a later
-- auto-sized label).
local function bodyFrame(parent)
  return framePool.Acquire(parent)
end

local function bodyTex(parent, c, layer)
  local t = texPool.Acquire(parent)
  t:SetDrawLayer(layer or "BACKGROUND")
  setTex(t, c)
  return t
end

local function bodyFS(parent, size, color, flags)
  local fs = fsPool.Acquire(parent)
  fs:SetSize(0, 0)
  fs:SetJustifyH("LEFT")
  fs:SetFont(STANDARD_TEXT_FONT, size, flags or "")
  local c = color or { 1, 1, 1 }
  fs:SetTextColor(c[1], c[2], c[3], c[4] or 1)
  return fs
end

local function bodyBorder(frame, c)
  local edges = {}
  for i = 1, 4 do edges[i] = bodyTex(frame, c, "BORDER") end
  edges[1]:SetPoint("TOPLEFT"); edges[1]:SetPoint("TOPRIGHT"); edges[1]:SetHeight(1)
  edges[2]:SetPoint("BOTTOMLEFT"); edges[2]:SetPoint("BOTTOMRIGHT"); edges[2]:SetHeight(1)
  edges[3]:SetPoint("TOPLEFT"); edges[3]:SetPoint("BOTTOMLEFT"); edges[3]:SetWidth(1)
  edges[4]:SetPoint("TOPRIGHT"); edges[4]:SetPoint("BOTTOMRIGHT"); edges[4]:SetWidth(1)
  return edges
end

local function qcolor(q)
  local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
  if c then return c.r, c.g, c.b end
  return 1, 1, 1
end

local function catchWord(n) return n == 1 and L["catch"] or L["catches"] end

local function fmtNum(n)
  n = n or 0
  local s = tostring(math.floor(n + 0.5))
  local sign, digits = s:match("^(%-?)(%d+)$")
  if not digits then return s end
  digits = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return sign .. digits
end

-- Money string. Auctionator prices come in copper; precision is the `priceDetail` setting:
-- "gold" (floor to whole gold), "goldsilver", or "all". nil copper => "?" (no price data).
local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"
local function goldStr(copper)
  if not copper then return "? " .. GOLD_ICON end
  local s = ns.GetSettings and ns.GetSettings()
  local detail = (s and s.priceDetail) or "goldsilver"
  local g = math.floor(copper / 10000)
  if detail == "gold" then
    return fmtNum(g) .. " " .. GOLD_ICON
  end
  local silver = math.floor((copper % 10000) / 100)
  if detail == "goldsilver" then
    return fmtNum(g) .. " " .. GOLD_ICON .. " " .. silver .. " " .. SILVER_ICON
  end
  return fmtNum(g) .. " " .. GOLD_ICON .. " " .. silver .. " " .. SILVER_ICON
       .. " " .. (copper % 100) .. " " .. COPPER_ICON
end

-- Confirmation for the "New session" button -- guards against an accidental session wipe.
-- The lifetime history is untouched; only the in-memory session counts/timer reset.
StaticPopupDialogs["FISHTIPS_RESET_SESSION"] = {
  text = L["Start a new session? This clears the current session's catches and timer. Your lifetime history is kept."],
  button1 = YES,
  button2 = NO,
  OnAccept = function() if ns.ResetSession then ns.ResetSession() end end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Body-only (pooled): called from the two body builders each rebuild.
local function makeBadge(parent, p, text)
  local b = bodyFrame(parent)
  local bg = bodyTex(b, { p.accent[1], p.accent[2], p.accent[3], 0.18 }, "BACKGROUND")
  bg:SetAllPoints()
  local fs = bodyFS(b, 10, p.accentText or p.accent)
  fs:SetPoint("CENTER")
  fs:SetText(text)
  b:SetSize(fs:GetStringWidth() + 14, 15)
  return b
end

-- ---------------------------------------------------------------------------
-- Mini dropdown (custom, theme-neutral; used for scope + options)
-- ---------------------------------------------------------------------------
function UI.CreateDropdown(parent, width)
  local dd = CreateFrame("Button", nil, parent)
  dd:SetSize(width, 22)
  dd.bg = MakeTex(dd, { 1, 1, 1, 0.05 }); dd.bg:SetAllPoints()
  dd.border = MakeBorder(dd, { 1, 1, 1, 0.10 })
  dd.label = MakeFS(dd, 12, { 0.9, 0.9, 0.9 })
  dd.label:SetPoint("LEFT", 8, 0); dd.label:SetPoint("RIGHT", -18, 0); dd.label:SetJustifyH("LEFT")
  dd.arrow = MakeFS(dd, 9, { 0.6, 0.6, 0.6 })
  dd.arrow:SetPoint("RIGHT", -7, 0); dd.arrow:SetText("v")

  local menu = CreateFrame("Frame", nil, dd); dd.menu = menu
  menu:SetFrameStrata("DIALOG")
  menu:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
  menu.bg = MakeTex(menu, { 0.05, 0.05, 0.07, 0.98 }); menu.bg:SetAllPoints()
  menu.border = MakeBorder(menu, { 1, 1, 1, 0.12 })
  menu.rows = {}
  menu:Hide()

  dd:SetScript("OnClick", function(self) self.menu:SetShown(not self.menu:IsShown()) end)

  function dd:SetValue(text) self.label:SetText(text or "") end

  function dd:SetItems(list, currentKey, onSelect)
    for _, r in ipairs(self.menu.rows) do r:Hide() end
    local rowH = 20
    for i, item in ipairs(list) do
      local r = self.menu.rows[i]
      if not r then
        r = CreateFrame("Button", nil, self.menu)
        r.hl = r:CreateTexture(nil, "ARTWORK"); r.hl:SetColorTexture(1, 1, 1, 0.08)
        r.hl:SetAllPoints(); r.hl:Hide()
        r.fs = MakeFS(r, 12, { 0.88, 0.88, 0.9 }); r.fs:SetPoint("LEFT", 8, 0)
        r:SetScript("OnEnter", function(s) s.hl:Show() end)
        r:SetScript("OnLeave", function(s) s.hl:Hide() end)
        -- One shared handler per row, installed once; SetItems only updates the row's
        -- key/onSelect fields (no per-pass closure churn).
        r:SetScript("OnClick", function(s)
          menu:Hide()
          if s.onSelect then s.onSelect(s.key) end
        end)
        self.menu.rows[i] = r
      end
      r:SetSize(width, rowH)
      r:SetPoint("TOPLEFT", 0, -((i - 1) * rowH) - 2)
      r.fs:SetText(item.name)
      if item.key == currentKey then
        r.fs:SetTextColor(1, 0.82, 0.42)
      else
        r.fs:SetTextColor(0.88, 0.88, 0.9)
      end
      r.key = item.key
      r.onSelect = onSelect
      r:Show()
    end
    self.menu:SetSize(width, #list * rowH + 4)
  end

  return dd
end

-- ---------------------------------------------------------------------------
-- Scope helpers
-- ---------------------------------------------------------------------------
local function validScope(scope)
  for _, sc in ipairs(ns.GetScopes()) do
    if sc.key == scope then return true end
  end
  return false
end

local function ensureScope()
  local s = ns.GetSettings and ns.GetSettings()
  local want = s and s.scope
  if want and validScope(want) then UI.scope = want; return end
  local me = ns.CharKey()
  if me and validScope(me) then UI.scope = me; return end
  local scopes = ns.GetScopes()
  UI.scope = scopes[1] and scopes[1].key or "account"
end

local function gatherData()
  local mode = UI.mode
  local loc = ns.GetCurrentLocation()
  -- Session is always the current character; Lifetime follows the scope selector.
  local sessionScope = ns.GetSessionScope()
  local lifeScope = (mode == "session") and sessionScope or UI.scope
  -- The top-zones chart renders only in the tiles layouts' Lifetime view; skip the
  -- full zone walk everywhere else (session view, classic layout).
  local wantZones = mode == "lifetime" and THEME_LAYOUT[UI.themeKey] ~= "classic"
  return {
    mode = mode, loc = loc,
    session = ns.GetTotals(sessionScope, "session"),
    lifetime = ns.GetTotals(lifeScope, "lifetime"),
    -- Session view lists the WHOLE session (all locations, merged) -- a pool-hunter's
    -- catches must not vanish from the list when they fly to the next pool. Location
    -- filtering stays a Lifetime-view concern.
    items = (mode == "session") and ns.GetSessionItems(sessionScope)
            or ns.GetLocationItems(lifeScope, mode, loc.zone, loc.subZone),
    zones = wantZones and ns.GetZoneTotals(lifeScope, "lifetime") or nil,
  }
end

-- ---------------------------------------------------------------------------
-- Item row (returns the new y cursor). Rarity-colored name (junk = quality 0 reads
-- gray via ITEM_QUALITY_COLORS), a thin frequency bar beneath, count on the right.
-- No left swatch/stripe -- rarity is conveyed by the name color.
-- ---------------------------------------------------------------------------
local function renderRow(body, p, it, y, maxCount, total, priced)
  local row = bodyFrame(body)
  row:SetPoint("TOPLEFT", PAD, y); row:SetSize(INNER, 28)
  local qr, qg, qb = qcolor(it.quality)
  -- Junk (quality 0) reads close to white at the default poor-gray; push it well dimmer so
  -- it visibly recedes from the worthwhile catches.
  if (it.quality or 1) == 0 then qr, qg, qb = 0.36, 0.36, 0.36 end
  local name = bodyFS(row, 13, { qr, qg, qb })
  name:SetPoint("TOPLEFT", 0, -1); name:SetPoint("RIGHT", -82, 0); name:SetJustifyH("LEFT")
  -- Optional Auctionator value of this catch (count * unit price), appended after the name.
  if priced then
    local unit = ns.GetItemPrice(it.itemID)
    name:SetText(it.name .. "  (" .. goldStr(unit and unit * (it.count or 0) or nil) .. ")")
  else
    name:SetText(it.name)
  end
  local trackW = INNER - 90
  local track = bodyTex(row, { 1, 1, 1, 0.07 }, "ARTWORK")
  track:SetPoint("TOPLEFT", 0, -19); track:SetSize(trackW, 3)
  local frac = maxCount > 0 and (it.count / maxCount) or 0
  local fill = bodyTex(row, { p.accent[1], p.accent[2], p.accent[3], 0.55 }, "OVERLAY")
  fill:SetPoint("TOPLEFT", track, "TOPLEFT"); fill:SetSize(math.max(2, trackW * frac), 3)
  -- count, then its share of the location's catches in gray parentheses
  local share = (total and total > 0) and math.floor(it.count / total * 100 + 0.5) or 0
  local pct = bodyFS(row, 12, p.textSecondary)
  pct:SetPoint("RIGHT", -2, 0); pct:SetText("(" .. share .. "%)")
  local cnt = bodyFS(row, 13, p.textPrimary)
  cnt:SetPoint("RIGHT", pct, "LEFT", -4, 0); cnt:SetText(tostring(it.count))
  return y - 30
end

local function renderItems(body, p, data, y)
  local items = data.items
  if #items == 0 then
    local none = bodyFS(body, 12, p.textSecondary)
    none:SetPoint("TOPLEFT", PAD, y - 2); none:SetText(L["No catches here yet."])
    return y - 24
  end
  -- Prices are session-only (lifetime price data would be stale) and opt-in.
  local priced = data.mode == "session" and ns.PricingActive and ns.PricingActive()
  local maxCount = items[1].count or 1
  local total = 0
  for i = 1, #items do total = total + (items[i].count or 0) end
  local shown = math.min(#items, 6)
  for i = 1, shown do
    y = renderRow(body, p, items[i], y, maxCount, total, priced)
  end
  if #items > shown then
    local more = bodyFS(body, 11, p.textSecondary)
    more:SetPoint("TOPLEFT", PAD, y - 2)
    more:SetText((L["+%d more"]):format(#items - shown))
    y = y - 18
  end
  return y - 4
end

local function locText(loc)
  if loc.subZone and loc.subZone ~= "" then
    return loc.zone .. "  -  " .. loc.subZone
  end
  return loc.zone
end

-- ---------------------------------------------------------------------------
-- Body layouts
-- ---------------------------------------------------------------------------
local function BuildBody_Classic(body, p, data)
  local y = -8

  local hero = bodyFrame(body)
  hero:SetPoint("TOPLEFT", PAD, y); hero:SetSize(INNER, 58)
  local heroBg = bodyTex(hero, { p.accent[1], p.accent[2], p.accent[3], 0.08 })
  heroBg:SetAllPoints()
  local accentBar = bodyTex(hero, p.accent, "ARTWORK")
  accentBar:SetPoint("TOPLEFT"); accentBar:SetPoint("BOTTOMLEFT"); accentBar:SetWidth(3)
  local loc = bodyFS(hero, 13, p.textPrimary)
  loc:SetPoint("TOPLEFT", 10, -8); loc:SetText(locText(data.loc))
  if data.loc.isSpecialPool then
    local badge = makeBadge(hero, p, L["Special pool"])
    badge:SetPoint("TOPRIGHT", -8, -7)
  end
  local function stat(ax, value, label, color)
    local v = bodyFS(hero, 16, color or p.textPrimary)
    v:SetPoint("TOPLEFT", ax, -26); v:SetText(value)
    local l = bodyFS(hero, 11, p.textSecondary)
    l:SetPoint("TOPLEFT", ax, -44); l:SetText(label)
  end
  local totals = (data.mode == "session") and data.session or data.lifetime
  local rate = totals.ratePerHour and tostring(totals.ratePerHour) or "-"
  stat(12, tostring(totals.catches), L["catches"])
  stat(120, tostring(totals.casts), L["casts"])
  stat(216, rate, L["fish / hr"], p.accent)
  y = y - 58 - 10

  local lbl = bodyFS(body, 11, p.textSecondary)
  lbl:SetPoint("TOPLEFT", PAD, y)
  lbl:SetText(data.mode == "session" and L["Catches (this session)"] or L["Catches (lifetime)"])
  y = y - 18

  y = renderItems(body, p, data, y)

  local footer = bodyFrame(body)
  footer:SetPoint("TOPLEFT", PAD, y); footer:SetSize(INNER, 24)
  local fbg = bodyTex(footer, { 1, 1, 1, 0.04 }); fbg:SetAllPoints()
  local mins = math.floor((data.session.elapsed or 0) / 60 + 0.5)
  local ftext = string.format(L["%d casts    %d %s    %s/hr    %dm"],
    data.session.casts, data.session.catches, catchWord(data.session.catches),
    data.session.ratePerHour or 0, mins)
  local ff = bodyFS(footer, 11, p.textSecondary)
  ff:SetPoint("LEFT", 8, 0); ff:SetText(ftext)
  -- Right-aligned session value (whole session, all zones), when Auctionator pricing is on.
  if data.mode == "session" and ns.PricingActive and ns.PricingActive() then
    local fg = bodyFS(footer, 11, p.textSecondary)
    fg:SetPoint("RIGHT", -8, 0); fg:SetText(goldStr(ns.GetSessionValue()))
  end
  y = y - 24

  return -y + 8
end

local function BuildBody_Tiles(body, p, data)
  local y = -8

  -- Location box. The catch counts live in the tiles-free body below + the footer stat bar,
  -- so this header carries just the current zone/subzone (no cast count -- it's in the footer).
  local block = bodyFrame(body)
  block:SetPoint("TOPLEFT", PAD, y); block:SetSize(INNER, 32)
  local bbg = bodyTex(block, { p.accent[1], p.accent[2], p.accent[3], 0.09 })
  bbg:SetAllPoints()
  bodyBorder(block, { p.accent[1], p.accent[2], p.accent[3], 0.28 })
  local loc = bodyFS(block, 13, p.textPrimary)
  loc:SetPoint("LEFT", 10, 0); loc:SetText(locText(data.loc))
  if data.loc.isSpecialPool then
    local badge = makeBadge(block, p, L["Special pool"])
    badge:SetPoint("RIGHT", -8, 0)
  end
  y = y - 32 - 10

  local lbl = bodyFS(body, 11, p.textSecondary)
  lbl:SetPoint("TOPLEFT", PAD, y)
  lbl:SetText(data.mode == "session" and L["Catches (this session)"] or L["Catches (lifetime)"])
  y = y - 18

  y = renderItems(body, p, data, y)

  -- Top-zones chart -- Lifetime view only. Current zone row highlighted in the accent.
  if data.mode == "lifetime" then
    local divider = bodyTex(body, { 1, 1, 1, 0.06 }, "ARTWORK")
    divider:SetPoint("TOPLEFT", PAD, y); divider:SetSize(INNER, 1)
    y = y - 9
    local zlbl = bodyFS(body, 11, p.textSecondary)
    zlbl:SetPoint("TOPLEFT", PAD, y); zlbl:SetText(L["Top zones"])
    y = y - 18

    local zones = data.zones or {}  -- gatherData only walks zones when this chart renders
    local zmax = zones[1] and zones[1].catches or 1
    local zshown = math.min(#zones, 4)
    for i = 1, zshown do
      local z = zones[i]
      local current = (z.zone == data.loc.zone)
      local nameC = current and p.accent or p.textPrimary
      local zn = bodyFS(body, 12, nameC)
      zn:SetPoint("TOPLEFT", PAD, y); zn:SetWidth(108); zn:SetJustifyH("LEFT")
      zn:SetText(z.zone)
      local track = bodyTex(body, { 1, 1, 1, 0.06 }, "ARTWORK")
      track:SetPoint("TOPLEFT", PAD + 116, y - 4); track:SetSize(INNER - 116 - 44, 7)
      local frac = zmax > 0 and (z.catches / zmax) or 0
      local fa = current and 1.0 or 0.7
      local fill = bodyTex(body, { p.accent[1], p.accent[2], p.accent[3], fa }, "OVERLAY")
      fill:SetPoint("TOPLEFT", track, "TOPLEFT")
      fill:SetSize(math.max(2, (INNER - 116 - 44) * frac), 7)
      local zc = bodyFS(body, 12, p.textSecondary)
      zc:SetPoint("TOPRIGHT", body, "TOPLEFT", INNER + PAD, y); zc:SetJustifyH("RIGHT")
      zc:SetText(fmtNum(z.catches))
      y = y - 18
    end
    if zshown == 0 then
      local none = bodyFS(body, 11, p.textSecondary)
      none:SetPoint("TOPLEFT", PAD, y); none:SetText(L["No zones tracked yet."])
      y = y - 18
    end
  end

  -- Footer stat bar (session totals) -- placeholder strip for future stats.
  y = y - 4
  local footer = bodyFrame(body)
  footer:SetPoint("TOPLEFT", PAD, y); footer:SetSize(INNER, 24)
  local fbg = bodyTex(footer, { 1, 1, 1, 0.04 }); fbg:SetAllPoints()
  local mins = math.floor((data.session.elapsed or 0) / 60 + 0.5)
  local casts = data.session.casts or 0
  local ftext = string.format(L["%d %s    %d %s    %s/hr    %dm"],
    casts, casts == 1 and L["cast"] or L["casts"], data.session.catches,
    catchWord(data.session.catches), data.session.ratePerHour or 0, mins)
  local ff = bodyFS(footer, 11, p.textSecondary)
  ff:SetPoint("LEFT", 8, 0); ff:SetText(ftext)
  -- Right-aligned session value (whole session, all zones), when Auctionator pricing is on.
  if data.mode == "session" and ns.PricingActive and ns.PricingActive() then
    local fg = bodyFS(footer, 11, p.textSecondary)
    fg:SetPoint("RIGHT", -8, 0); fg:SetText(goldStr(ns.GetSessionValue()))
  end
  y = y - 24

  return -y + 8
end

-- ---------------------------------------------------------------------------
-- Chrome + theme application
-- ---------------------------------------------------------------------------
local function savePos()
  local s = ns.GetSettings and ns.GetSettings()
  if not s or not UI.window then return end
  local point, _, relPoint, x, y = UI.window:GetPoint()
  s.uiPos = { point, relPoint, x, y }
end

local function restorePos()
  local s = ns.GetSettings and ns.GetSettings()
  UI.window:ClearAllPoints()
  if s and s.uiPos then
    UI.window:SetPoint(s.uiPos[1], UIParent, s.uiPos[2], s.uiPos[3], s.uiPos[4])
  else
    UI.window:SetPoint("CENTER")
  end
end

local function saveCompactPos()
  local s = ns.GetSettings and ns.GetSettings()
  if not s or not UI.compact then return end
  local point, _, relPoint, x, y = UI.compact:GetPoint()
  s.compactPos = { point, relPoint, x, y }
end

local function restoreCompactPos()
  local s = ns.GetSettings and ns.GetSettings()
  UI.compact:ClearAllPoints()
  if s and s.compactPos then
    UI.compact:SetPoint(s.compactPos[1], UIParent, s.compactPos[2], s.compactPos[3], s.compactPos[4])
  else
    UI.compact:SetPoint("CENTER", 0, -120)
  end
end

function UI.SetModeActive(mode)
  UI.mode = mode
  local p = PALETTES[UI.themeKey]
  for key, btn in pairs(UI.modeBtns) do
    if key == mode then
      btn.bg:SetColorTexture(p.accent[1], p.accent[2], p.accent[3], 0.16)
      btn.fs:SetTextColor(p.accent[1], p.accent[2], p.accent[3])
    else
      btn.bg:SetColorTexture(1, 1, 1, 0.04)
      btn.fs:SetTextColor(0.6, 0.6, 0.6)
    end
  end
end

local function onScopeSelect(key)
  markOwned()
  UI.scope = key
  if ns.SetSetting then ns.SetSetting("scope", key) end
  UI.Refresh()
end

function UI.UpdateControls()
  local scopes = ns.GetScopes()
  local label
  for _, sc in ipairs(scopes) do
    if sc.key == UI.scope then label = sc.name end
  end
  UI.scopeDD:SetValue(label or UI.scope or "")
  UI.scopeDD:SetItems(scopes, UI.scope, onScopeSelect)
  UI.SetModeActive(UI.mode)
  -- Scope only applies to Lifetime; Session is always the current character. The "New session"
  -- reset is the converse -- only meaningful in the Session view.
  if UI.mode == "lifetime" then
    UI.scopeDD:Show()
    if UI.newSessionBtn then UI.newSessionBtn:Hide() end
  else
    UI.scopeDD:Hide()
    if UI.scopeDD.menu then UI.scopeDD.menu:Hide() end
    if UI.newSessionBtn then UI.newSessionBtn:Show() end
  end
end

function UI.RebuildBody()
  if not UI.window then return end
  -- The body frame is created ONCE and kept; its content comes from the widget pools,
  -- so a rebuild is release-everything + re-acquire (frames are never GC'd -- the old
  -- SetParent(nil) teardown leaked every widget it ever made).
  releaseBodyWidgets()
  local body = UI.body
  if not body then
    body = CreateFrame("Frame", nil, UI.window)
    UI.body = body
    -- Full window width; the PAD insets are applied inside the builders. y -60 sits just
    -- below the controls row (controls: top -32, height 22, +6 gap).
    body:SetPoint("TOPLEFT", UI.window, "TOPLEFT", 0, -60)
    body:SetPoint("TOPRIGHT", UI.window, "TOPRIGHT", 0, -60)
  end
  local p = PALETTES[UI.themeKey]
  local data = gatherData()
  local h
  if THEME_LAYOUT[UI.themeKey] == "classic" then
    h = BuildBody_Classic(body, p, data)
  else
    h = BuildBody_Tiles(body, p, data)
  end
  body:SetHeight(h)
  UI.window:SetHeight(68 + h)
end

function UI.ApplyTheme(key)
  if not UI.window then return end
  if not THEME_LAYOUT[key] then key = "blend" end
  UI.themeKey = key
  local p = PALETTES[key]
  setTex(UI.window.bg, p.bg)
  recolorBorder(UI.window.border, p.border)
  UI.title:SetTextColor(p.title[1], p.title[2], p.title[3])
  UI.scopeDD.label:SetTextColor(p.textPrimary[1], p.textPrimary[2], p.textPrimary[3])
  UI.RebuildBody()
  UI.SetModeActive(UI.mode)
end

local function BuildWindow()
  local window = CreateFrame("Frame", "FishTipsWindow", UIParent)
  UI.window = window
  window:SetSize(WIN_W, 160)
  window:SetClampedToScreen(true)
  window:SetFrameStrata("MEDIUM")
  window.bg = MakeTex(window, PALETTES.blend.bg, "BACKGROUND")
  window.bg:SetAllPoints()
  window.border = MakeBorder(window, PALETTES.blend.border)

  window:SetMovable(true); window:EnableMouse(true)
  window:RegisterForDrag("LeftButton")
  window:SetScript("OnDragStart", function(self) markOwned(); self:StartMoving() end)
  window:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePos() end)

  local fishSwatch = MakeTex(window, PALETTES.blend.accent, "ARTWORK")
  fishSwatch:SetPoint("TOPLEFT", 12, -10); fishSwatch:SetSize(12, 12)
  UI.title = MakeFS(window, 14, PALETTES.blend.title)
  UI.title:SetPoint("LEFT", fishSwatch, "RIGHT", 7, 0); UI.title:SetText("Fish & Tips")

  local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, -1)
  close:SetScript("OnClick", function() UI.Toggle() end)

  local collapse = CreateFrame("Button", nil, window)
  collapse:SetSize(22, 22); collapse:SetPoint("RIGHT", close, "LEFT", 4, 0)
  local cfs = MakeFS(collapse, 18, { 0.6, 0.6, 0.6 }); cfs:SetPoint("CENTER", 0, 3); cfs:SetText("_")
  collapse:SetScript("OnEnter", function() cfs:SetTextColor(0.95, 0.95, 0.95) end)
  collapse:SetScript("OnLeave", function() cfs:SetTextColor(0.6, 0.6, 0.6) end)
  collapse:SetScript("OnClick", function() markOwned(); UI.SetCollapsed(true) end)

  local gear = CreateFrame("Button", nil, window)
  gear:SetSize(20, 20); gear:SetPoint("RIGHT", collapse, "LEFT", 0, 0)
  local gicon = gear:CreateTexture(nil, "ARTWORK")
  gicon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
  gicon:SetAllPoints()
  gear:SetScript("OnClick", function() markOwned(); if ns.OpenConfig then ns.OpenConfig() end end)

  local controls = CreateFrame("Frame", nil, window)
  UI.controls = controls
  controls:SetPoint("TOPLEFT", PAD, -32)
  controls:SetPoint("TOPRIGHT", -PAD, -32)
  controls:SetHeight(22)

  UI.scopeDD = UI.CreateDropdown(controls, 150)
  UI.scopeDD:SetPoint("LEFT", 0, 0)

  UI.modeBtns = {}
  local function modeBtn(text, key)
    local btn = CreateFrame("Button", nil, controls)
    btn:SetSize(64, 20)
    btn.bg = MakeTex(btn, { 1, 1, 1, 0.04 }); btn.bg:SetAllPoints()
    btn.fs = MakeFS(btn, 12, { 0.6, 0.6, 0.6 }); btn.fs:SetPoint("CENTER"); btn.fs:SetText(text)
    btn:SetScript("OnClick", function()
      markOwned()
      UI.mode = key
      if ns.SetSetting then ns.SetSetting("statMode", key) end
      UI.UpdateControls()
      UI.RebuildBody()
      UI.RefreshCompact()
    end)
    UI.modeBtns[key] = btn
    return btn
  end
  local lifeBtn = modeBtn(L["Lifetime"], "lifetime")
  lifeBtn:SetPoint("RIGHT", 0, 0)
  local sessBtn = modeBtn(L["Session"], "session")
  sessBtn:SetPoint("RIGHT", lifeBtn, "LEFT", 4, 0)

  -- "New session" action -- sits left of the Session/Lifetime selector, shown in Session view
  -- only (UI.UpdateControls). Resets the live session; the persisted lifetime history is kept.
  local newSess = CreateFrame("Button", nil, controls)
  UI.newSessionBtn = newSess
  newSess:SetSize(96, 20)
  newSess.bg = MakeTex(newSess, { 1, 1, 1, 0.04 }); newSess.bg:SetAllPoints()
  newSess.fs = MakeFS(newSess, 12, { 0.6, 0.6, 0.6 })
  newSess.fs:SetPoint("CENTER"); newSess.fs:SetText(L["New session"])
  -- Left edge of the controls row -- the same slot the scope dropdown uses in Lifetime view.
  -- They never show together (scope = Lifetime only, this = Session only), so sharing it is fine.
  newSess:SetPoint("LEFT", 0, 0)
  newSess:SetScript("OnEnter", function(self) self.fs:SetTextColor(0.95, 0.95, 0.95) end)
  newSess:SetScript("OnLeave", function(self) self.fs:SetTextColor(0.6, 0.6, 0.6) end)
  newSess:SetScript("OnClick", function()
    markOwned()
    StaticPopup_Show("FISHTIPS_RESET_SESSION")  -- confirm before wiping the live session
  end)
end

-- ---------------------------------------------------------------------------
-- Compact strip
-- ---------------------------------------------------------------------------
function UI.BuildCompact()
  local c = CreateFrame("Frame", "FishTipsCompact", UIParent)
  UI.compact = c
  c:SetSize(200, 30); c:SetClampedToScreen(true); c:SetFrameStrata("MEDIUM")
  c.bg = MakeTex(c, { 0.043, 0.047, 0.067, 0.95 }); c.bg:SetAllPoints()
  c.border = MakeBorder(c, { 1, 1, 1, 0.10 })
  c:EnableMouse(true); c:SetMovable(true); c:RegisterForDrag("LeftButton")
  c:SetScript("OnDragStart", function(self) markOwned(); self:StartMoving() end)
  c:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); saveCompactPos() end)

  c.icon = MakeTex(c, { 0.608, 0.529, 0.961, 1 }, "ARTWORK")
  c.icon:SetPoint("LEFT", 9, 0); c.icon:SetSize(12, 12)
  c.text = MakeFS(c, 12, { 0.9, 0.9, 0.95 })
  c.text:SetPoint("LEFT", 27, 0)

  local expand = CreateFrame("Button", nil, c)
  expand:SetSize(22, 22); expand:SetPoint("RIGHT", -3, 0)
  local efs = MakeFS(expand, 16, { 0.55, 0.55, 0.6 }); efs:SetPoint("CENTER"); efs:SetText("+")
  expand:SetScript("OnEnter", function() efs:SetTextColor(0.95, 0.95, 0.95) end)
  expand:SetScript("OnLeave", function() efs:SetTextColor(0.55, 0.55, 0.6) end)
  expand:SetScript("OnClick", function() markOwned(); UI.SetCollapsed(false) end)
  c:Hide()
end

function UI.RefreshCompact()
  if not UI.compact then return end
  local loc = ns.GetCurrentLocation()
  -- Session data is keyed to the current character -- never the Lifetime scope
  -- selector, which can point at another character (or "account", summing every
  -- character's session) and would render a wrong/zero strip.
  local t = ns.GetTotals(ns.GetSessionScope(), "session")
  local where = (loc.subZone and loc.subZone ~= "") and loc.subZone or loc.zone
  local p = PALETTES[UI.themeKey or "blend"]
  setTex(UI.compact.icon, p.accent)
  local txt = string.format("%s    %d %s    %s/hr",
    where, t.catches, catchWord(t.catches), t.ratePerHour or 0)
  -- The strip is inherently session, so show the session value whenever pricing is on.
  if ns.PricingActive and ns.PricingActive() then
    txt = txt .. "    " .. goldStr(ns.GetSessionValue())
  end
  UI.compact.text:SetText(txt)
  UI.compact:SetWidth(math.max(180, UI.compact.text:GetStringWidth() + 72))
end

function UI.SetCollapsed(collapsed)
  if ns.SetSetting then ns.SetSetting("uiCollapsed", collapsed and true or false) end
  if collapsed then
    UI.window:Hide()
    UI.RefreshCompact()
    UI.compact:Show()
  else
    UI.compact:Hide()
    UI.window:Show()
    UI.Refresh()  -- keep: repaints a window dirtied while hidden (coalesced refreshes skip it)
  end
end

-- ---------------------------------------------------------------------------
-- Minimap button (custom)
-- ---------------------------------------------------------------------------
local function placeMinimap(angleDeg)
  if not UI.minimap then return end
  local a = math.rad(angleDeg)
  -- Half the live minimap width + margin, not a constant: Edit Mode can resize/rescale
  -- the minimap (the default 140-wide ring yields the classic 80).
  local r = (Minimap:GetWidth() / 2) + 10
  UI.minimap:ClearAllPoints()
  UI.minimap:SetPoint("CENTER", Minimap, "CENTER", r * math.cos(a), r * math.sin(a))
end
UI.PlaceMinimap = placeMinimap

local function minimapDragUpdate()
  local mx, my = Minimap:GetCenter()
  local scale = Minimap:GetEffectiveScale()
  local px, py = GetCursorPosition()
  px, py = px / scale, py / scale
  local deg = math.deg(math.atan2(py - my, px - mx))
  local s = ns.GetSettings and ns.GetSettings()
  if s then s.minimapAngle = deg end
  placeMinimap(deg)
end

function UI.SetMinimapShown(shown)
  if not UI.minimap then return end
  if shown then UI.minimap:Show() else UI.minimap:Hide() end
end

function UI.BuildMinimap()
  local b = CreateFrame("Button", "FishTipsMinimapButton", Minimap)
  UI.minimap = b
  b:SetSize(31, 31); b:SetFrameStrata("MEDIUM"); b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")

  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\inv_fishingpole_05")
  -- 17x17 at TOPLEFT (7,-6) centers the icon in the TrackingBorder ring's opening;
  -- the circular mask clips the square corners the ring art doesn't cover.
  icon:SetSize(17, 17); icon:SetPoint("TOPLEFT", 7, -6)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local mask = b:CreateMaskTexture()
  mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
    "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
  mask:SetAllPoints(icon)
  icon:AddMaskTexture(mask)
  local overlay = b:CreateTexture(nil, "OVERLAY")
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetSize(53, 53); overlay:SetPoint("TOPLEFT")

  b:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      if ns.OpenConfig then ns.OpenConfig() end
    else
      UI.Toggle()
    end
  end)
  b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", minimapDragUpdate) end)
  b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Fish & Tips")
    GameTooltip:AddLine(L["Left-click to show the stats window."], 0.8, 0.8, 0.8)
    GameTooltip:AddLine(L["Right-click for options."], 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  local s = ns.GetSettings and ns.GetSettings()
  placeMinimap((s and s.minimapAngle) or 200)
  if s and s.showMinimap == false then b:Hide() end

  -- The radius derives from the live minimap width, so re-place when Edit Mode
  -- resizes it. Cosmetic positioning of our own insecure button -- no protected calls.
  Minimap:HookScript("OnSizeChanged", function()
    local cur = ns.GetSettings and ns.GetSettings()
    placeMinimap((cur and cur.minimapAngle) or 200)
  end)
end

-- ---------------------------------------------------------------------------
-- Addon Compartment (Blizzard's addon drawer on the minimap)
-- ---------------------------------------------------------------------------
-- The TOC's ## AddonCompartmentFunc* directives resolve these by name, so all three
-- must be globals. The drawer entry is the default access path; the custom minimap
-- button above is opt-in (showMinimap, default off). Since 11.0 the handlers receive
-- (addonName, buttonName) with no menu-button frame, so the tooltip anchors to the
-- compartment frame when the client doesn't hand us a region.

function FishTips_OnAddonCompartmentClick(_, buttonName)
  if buttonName == "RightButton" then
    if ns.OpenConfig then ns.OpenConfig() end
  else
    UI.Toggle()
  end
end

function FishTips_OnAddonCompartmentEnter(_, anchor)
  local owner = (type(anchor) == "table" and anchor.GetObjectType and anchor)
    or AddonCompartmentFrame
  if not owner then return end
  GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
  GameTooltip:AddLine("Fish & Tips")
  GameTooltip:AddLine(L["Left-click to show the stats window."], 0.8, 0.8, 0.8)
  GameTooltip:AddLine(L["Right-click for options."], 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

function FishTips_OnAddonCompartmentLeave()
  GameTooltip:Hide()
end

-- ---------------------------------------------------------------------------
-- Public toggle + refresh
-- ---------------------------------------------------------------------------
function UI.Toggle()
  markOwned()  -- a manual show/hide always takes ownership from auto-open
  local s = ns.GetSettings and ns.GetSettings()
  if s and s.uiCollapsed then
    if UI.compact:IsShown() then
      UI.compact:Hide()
      if ns.SetSetting then ns.SetSetting("uiShown", false) end
    else
      UI.RefreshCompact(); UI.compact:Show()
      if ns.SetSetting then ns.SetSetting("uiShown", true) end
    end
  else
    if UI.window:IsShown() then
      UI.window:Hide()
      if ns.SetSetting then ns.SetSetting("uiShown", false) end
    else
      -- keep the Refresh: it repaints a window dirtied while hidden (coalesced refreshes skip it)
      UI.window:Show(); UI.Refresh()
      if ns.SetSetting then ns.SetSetting("uiShown", true) end
    end
  end
end

function UI.Refresh()
  if not UI.window then return end
  ensureScope()
  UI.UpdateControls()
  UI.RebuildBody()
  UI.RefreshCompact()
end

-- Auto-open on fishing start. `mode` = "full" (the stats window) or "collapsed" (the compact
-- strip). Acts only when the UI is not already up, so it never fights a surface the player is
-- using. Transient: it never persists uiShown, so it can't override a manual hide on the next
-- login. It does align the collapsed form to `mode` (via SetCollapsed) so the toggle/state
-- stay consistent.
function UI.ShowWindow(mode)
  if not UI.window then return end
  if UI.window:IsShown() or (UI.compact and UI.compact:IsShown()) then return end
  UI.SetCollapsed(mode == "collapsed")
  UI.autoShown = true  -- auto-hide may tuck this surface away when the session pauses
end

function UI.Build()
  if UI.window then return end
  BuildWindow()
  UI.BuildCompact()
  UI.BuildMinimap()

  local s = ns.GetSettings and ns.GetSettings()
  UI.mode = (s and s.statMode) or "session"
  ensureScope()
  UI.ApplyTheme((s and s.theme) or "blend")
  UI.UpdateControls()
  restorePos()
  restoreCompactPos()

  if s and s.uiShown then
    if s.uiCollapsed then UI.RefreshCompact(); UI.compact:Show() else UI.window:Show() end
  else
    UI.window:Hide(); UI.compact:Hide()
  end
end

local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN")
ef:SetScript("OnEvent", function()
  UI.Build()
  -- Coalesced refresh: several data events can land in one frame (a zone change plus a
  -- cast; settings toggles), so the subscriber only schedules ONE flush for the next
  -- frame. Visibility is decided at flush time, and only the visible surface repaints:
  -- with just the compact strip up, the hidden full window is NOT rebuilt -- it simply
  -- repaints on show (every show path calls UI.Refresh).
  local refreshPending = false
  local function flushRefresh()
    refreshPending = false
    if UI.window and UI.window:IsShown() then
      UI.Refresh()
    elseif UI.compact and UI.compact:IsShown() then
      UI.RefreshCompact()
    end
  end
  ns.RegisterRefresh(function()
    if refreshPending then return end
    refreshPending = true
    if C_Timer and C_Timer.After then C_Timer.After(0, flushRefresh) else flushRefresh() end
  end)
  ns.RegisterFishingStart(function()
    local s = ns.GetSettings and ns.GetSettings()
    local mode = (s and s.autoOpen) or "full"
    if mode ~= "off" then UI.ShowWindow(mode) end
  end)
  -- The symmetric half of auto-open: when the session pauses (grace minutes after the
  -- last cast), tuck away the surface auto-open showed. Never a surface the player
  -- opened or touched (any interaction runs markOwned), never one under the mouse
  -- (it's in use -- the next fishing stop re-arms the pause), and uiShown is never
  -- persisted: like auto-open, auto-hide is transient. Requires sessionPause too: the
  -- options panel nests auto-hide under the pause checkbox, so its gray-out must not lie.
  ns.RegisterSessionPause(function()
    local s = ns.GetSettings and ns.GetSettings()
    if not (s and s.autoHide and s.sessionPause) then return end
    if not UI.autoShown then return end
    local surface
    if UI.window and UI.window:IsShown() then surface = UI.window
    elseif UI.compact and UI.compact:IsShown() then surface = UI.compact end
    if not surface then UI.autoShown = false; return end
    if surface:IsMouseOver() then return end
    surface:Hide()
    UI.autoShown = false
  end)
end)
