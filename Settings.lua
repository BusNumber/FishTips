local addonName, ns = ...

-- Settings.lua -- settings layer: defaults/sanitizing for db.settings (account-wide
-- display + behavior), the options panel, and the slash commands. Owns ns.InitSettings /
-- ns.GetSettings. The panel uses the modern Settings API (Settings.RegisterVerticalLayout-
-- Category + RegisterAddOnSetting), so the controls match current Blizzard options pages and
-- the native "Defaults" button resets every registered setting for free. Theme and compact
-- state are additive display settings, so they do NOT bump DB_VERSION; defaults are filled
-- with `== nil` checks so a persisted `false` survives.

local L = ns.L  -- user-facing strings go through the locale table (English keys)

local DEFAULTS = {
  theme = "blend",          -- locked to "blend"; engine kept for future custom themes
  statMode = "session",     -- "session" | "lifetime"
  scope = nil,              -- last selected scope key; nil => current character
  showMinimap = false,      -- opt-in; the Addon Compartment entry is the default access path
  minimapAngle = 200,       -- degrees around the ring
  castMode = "off",         -- cast trigger: "off" | "doubleclick" | "key" | "both"
  castDelay = 0.3,          -- double-click window (seconds)
  autoLoot = true,          -- auto-loot a fishing catch (read live by Core's loot handler)
  sessionEnd = "idle",      -- when a NEW session starts: "manual" | "idle" | "zone" | "zoneidle"
  sessionIdleMinutes = 30,  -- inactivity threshold (minutes since last cast) for idle/zoneidle
  sessionPause = true,      -- session clock counts inter-cast gaps only up to the grace below
  sessionGraceMinutes = 5,  -- per-gap cap on counted time; also the auto-hide delay
  autoHide = true,          -- hide an AUTO-OPENED surface when the session pauses
  includeJunk = true,       -- show gray (quality-0) catches in the stats window + totals
  auctionatorPrices = true, -- show session gold values from Auctionator (only renders if it's installed)
  priceDetail = "gold",     -- price precision: "gold" | "goldsilver" | "all" (picker deferred; pinned to gold)
  autoOpen = "full",        -- on fishing start, show: "off" | "full" (window) | "collapsed" (strip)
  demo = false,             -- dev: back the seams with the demo dataset
  uiShown = false,
  uiCollapsed = false,
  uiPos = nil,
  compactPos = nil,
}

local settings
local categoryID
local RegisterPanel -- forward decl; defined below, called from ns.InitSettings

local function applyDefaults(s)
  -- Migrate the old boolean autoOpenOnFishing -> the autoOpen enum (before the default-fill,
  -- so a stored `false` maps to "off" rather than being lost). Additive -- no DB_VERSION bump.
  if s.autoOpen == nil and s.autoOpenOnFishing ~= nil then
    s.autoOpen = s.autoOpenOnFishing and "full" or "off"
  end
  s.autoOpenOnFishing = nil
  for k, v in pairs(DEFAULTS) do
    if s[k] == nil then s[k] = v end
  end
  if s.autoOpen ~= "off" and s.autoOpen ~= "full" and s.autoOpen ~= "collapsed" then
    s.autoOpen = "full"
  end
  if s.theme ~= "classic" and s.theme ~= "modern" and s.theme ~= "blend" then
    s.theme = "blend"
  end
  if s.statMode ~= "session" and s.statMode ~= "lifetime" then
    s.statMode = "session"
  end
  if s.castMode ~= "off" and s.castMode ~= "doubleclick"
     and s.castMode ~= "key" and s.castMode ~= "both" then
    s.castMode = "off"
  end
  if type(s.castDelay) ~= "number" or s.castDelay < 0.1 then s.castDelay = 0.1
  elseif s.castDelay > 1.0 then s.castDelay = 1.0 end
  if s.sessionEnd ~= "manual" and s.sessionEnd ~= "idle"
     and s.sessionEnd ~= "zone" and s.sessionEnd ~= "zoneidle" then
    s.sessionEnd = DEFAULTS.sessionEnd
  end
  if type(s.sessionIdleMinutes) ~= "number" then s.sessionIdleMinutes = DEFAULTS.sessionIdleMinutes end
  if s.sessionIdleMinutes < 5 then s.sessionIdleMinutes = 5
  elseif s.sessionIdleMinutes > 120 then s.sessionIdleMinutes = 120 end
  if type(s.sessionGraceMinutes) ~= "number" then s.sessionGraceMinutes = DEFAULTS.sessionGraceMinutes end
  if s.sessionGraceMinutes < 1 then s.sessionGraceMinutes = 1
  elseif s.sessionGraceMinutes > 15 then s.sessionGraceMinutes = 15 end
  if type(s.sessionPause) ~= "boolean" then s.sessionPause = DEFAULTS.sessionPause end
  if type(s.autoHide) ~= "boolean" then s.autoHide = DEFAULTS.autoHide end
  if type(s.includeJunk) ~= "boolean" then s.includeJunk = DEFAULTS.includeJunk end
  if type(s.auctionatorPrices) ~= "boolean" then s.auctionatorPrices = DEFAULTS.auctionatorPrices end
  -- The precision picker isn't shipped yet (its options control is hidden), so pin everyone to
  -- gold for now. Restore the validation clamp below when the dropdown is re-enabled:
  --   if s.priceDetail ~= "gold" and ~= "goldsilver" and ~= "all" then s.priceDetail = "goldsilver" end
  s.priceDetail = "gold"
  s.doubleClickCast = nil  -- obsolete: replaced by castMode
end

function ns.InitSettings(db)
  db.settings = db.settings or {}
  settings = db.settings
  applyDefaults(settings)
  ns.settings = settings
  if ns.demoOn == nil then ns.demoOn = settings.demo and true or false end
  RegisterPanel()  -- bind the options panel to this (stable) settings table
end

function ns.GetSettings()
  return settings
end

function ns.SetSetting(key, value)
  if not settings then return end
  settings[key] = value
end

-- ---------------------------------------------------------------------------
-- Options panel (modern Settings API -- the canvas/custom-widget panel was replaced so
-- the controls match current Blizzard options pages and inherit the native "Defaults"
-- button, which resets every RegisterAddOnSetting below for free).
-- ---------------------------------------------------------------------------

-- Cast-mode dropdown options. Rebuilt each time the dropdown opens (the framework calls the
-- getter), so the wordings stay current.
local function CastModeOptions()
  local c = Settings.CreateControlTextContainer()
  c:Add("off",         L["Disabled"])
  c:Add("doubleclick", L["Double right-click"])
  c:Add("key",         L["Keybind (set in Key Bindings)"])
  c:Add("both",        L["Both"])
  return c:GetData()
end

local function AutoOpenOptions()
  local c = Settings.CreateControlTextContainer()
  c:Add("off",       L["Disabled"])
  c:Add("full",      L["Full window"])
  c:Add("collapsed", L["Compact view"])
  return c:GetData()
end

local function SessionEndOptions()
  local c = Settings.CreateControlTextContainer()
  c:Add("idle",     L["After inactivity"])
  c:Add("zone",     L["When the zone changes"])
  c:Add("zoneidle", L["Zone change + inactivity"])
  c:Add("manual",   L["Manually only"])
  return c:GetData()
end

-- defined via the forward-declared local so ns.InitSettings (above) can call it.
function RegisterPanel()
  if categoryID or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
  local category, layout = Settings.RegisterVerticalLayoutCategory("Fish & Tips")
  categoryID = category:GetID()

  -- Binds settings[key] to a control. RegisterAddOnSetting reads/writes that exact table, so
  -- `settings` (== db.settings) must never be replaced after InitSettings. The default and the
  -- Lua type() of the default drive the native Defaults button and the VarType.
  local function Register(key, name)
    return Settings.RegisterAddOnSetting(category, addonName .. "_" .. key, key,
      settings, type(DEFAULTS[key]), name, DEFAULTS[key])
  end

  -- Casting -------------------------------------------------------------------------------
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Casting"]))
  local castInit = Settings.CreateDropdown(category, Register("castMode", L["Auto-cast"]),
    CastModeOptions,
    L["How casting is triggered. Off by default -- pick a mode to enable click-to-cast."])
  Settings.SetOnValueChangedCallback(addonName .. "_castMode", function()
    if ns.Casting and ns.Casting.ApplyMode then ns.Casting.ApplyMode() end
  end)

  local delayOptions = Settings.CreateSliderOptions(0.1, 1.0, 0.05)
  delayOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
    function(value) return string.format("%.2fs", value) end)
  local delayInit = Settings.CreateSlider(category, Register("castDelay", L["Double-click delay"]),
    delayOptions, L["How quickly the two right-clicks must land to count as a double-click."])
  -- Only meaningful for the double-click paths; gray it out otherwise.
  delayInit:SetParentInitializer(castInit, function()
    return settings.castMode == "doubleclick" or settings.castMode == "both"
  end)

  -- Looting -------------------------------------------------------------------------------
  -- No side-effect callback: Core's loot handler reads settings.autoLoot live on each catch.
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Looting"]))
  Settings.CreateCheckbox(category, Register("autoLoot", L["Auto-loot catches"]),
    L["Automatically loot everything from a catch. Only applies to fishing loot."])

  -- Sessions ------------------------------------------------------------------------------
  -- Session boundaries and the clock are judged live in Core (lazily, at the next cast),
  -- so none of these need side-effect callbacks beyond a repaint where the display shifts.
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Sessions"]))
  local sessEndInit = Settings.CreateDropdown(category, Register("sessionEnd", L["Start a new session"]),
    SessionEndOptions,
    L["When your next cast begins a fresh session. The finished session stays on screen until you fish again."])
  local idleOptions = Settings.CreateSliderOptions(5, 120, 5)
  idleOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
    function(value) return string.format("%dm", value) end)
  local idleInit = Settings.CreateSlider(category, Register("sessionIdleMinutes", L["Inactivity timeout"]),
    idleOptions, L["How long since your last cast counts as inactivity."])
  -- Only meaningful for the inactivity-based modes; gray it out otherwise.
  idleInit:SetParentInitializer(sessEndInit, function()
    return settings.sessionEnd == "idle" or settings.sessionEnd == "zoneidle"
  end)
  local pauseInit = Settings.CreateCheckbox(category, Register("sessionPause", L["Pause session when not fishing"]),
    L["Keeps the fish/hour rate honest: each break between casts counts toward the session timer only up to the pause delay below."])
  Settings.SetOnValueChangedCallback(addonName .. "_sessionPause", function()
    if ns.FireRefresh then ns.FireRefresh() end
  end)
  -- Both the delay and auto-hide nest under the pause checkbox: with the pause off there
  -- is no pause moment, so auto-hide is genuinely inert (the UI subscriber checks
  -- sessionPause too) and the gray-out tells the truth.
  local graceOptions = Settings.CreateSliderOptions(1, 15, 1)
  graceOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
    function(value) return string.format("%dm", value) end)
  local graceInit = Settings.CreateSlider(category, Register("sessionGraceMinutes", L["Pause after"]),
    graceOptions,
    L["Minutes after your last cast before the session counts as paused. Caps how much of each break the timer counts, and delays the auto-hide below."])
  graceInit:SetParentInitializer(pauseInit, function() return settings.sessionPause end)
  Settings.SetOnValueChangedCallback(addonName .. "_sessionGraceMinutes", function()
    if ns.FireRefresh then ns.FireRefresh() end
  end)
  local autoHideInit = Settings.CreateCheckbox(category, Register("autoHide", L["Auto-hide stats window"]),
    L["Tucks away the auto-opened stats window (or compact strip) once the session pauses; it returns on your next cast. A window you opened yourself is never hidden."])
  autoHideInit:SetParentInitializer(pauseInit, function() return settings.sessionPause end)

  -- Stats window --------------------------------------------------------------------------
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(L["Stats window"]))
  Settings.CreateDropdown(category, Register("autoOpen", L["Auto-open when fishing"]), AutoOpenOptions,
    L["What to show when you start fishing: nothing, the full stats window, or the compact strip. Only acts when the window isn't already open."])
  Settings.CreateCheckbox(category, Register("showMinimap", L["Show minimap button"]),
    L["Show the Fish & Tips button on the minimap. Either way, the addon stays reachable from the minimap's addon compartment."])
  Settings.SetOnValueChangedCallback(addonName .. "_showMinimap", function()
    if ns.UI and ns.UI.SetMinimapShown then ns.UI.SetMinimapShown(settings.showMinimap) end
  end)
  Settings.CreateCheckbox(category, Register("includeJunk", L["Include junk items"]),
    L["Show gray (junk) catches in the stats window and totals."])
  Settings.SetOnValueChangedCallback(addonName .. "_includeJunk", function()
    if ns.FireRefresh then ns.FireRefresh() end
  end)
  -- Auctionator integration: show session gold values. On by default, but only ever renders when
  -- Auctionator is installed (ns.PricingActive gates on the API being present). Kept a plain
  -- top-level checkbox -- the only way to gray a Settings control out (SetParentInitializer)
  -- visually nests it under another, which we don't want. Without Auctionator it's simply inert.
  Settings.CreateCheckbox(category, Register("auctionatorPrices", L["Show Auctionator prices"]),
    L["Show estimated gold value (from Auctionator) for the current session. Requires the Auctionator addon."])
  Settings.SetOnValueChangedCallback(addonName .. "_auctionatorPrices", function()
    if ns.FireRefresh then ns.FireRefresh() end
  end)
  -- Price-precision picker (priceDetail) is deferred: the setting + goldStr branching exist, but
  -- the dropdown is intentionally not registered yet, so priceDetail stays pinned to "gold".
  -- (Demo data is a dev-only affordance, reachable via `/ft demo`; intentionally not surfaced here.)

  -- Footer: support link + version. The donate URL
  -- lives only in the TOC's X-Donate field (no field, no line); shown scheme-stripped as plain
  -- text since the client can't open a browser.
  local donate = C_AddOns.GetAddOnMetadata(addonName, "X-Donate")
  if donate then
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
      (L["Enjoying the addon? Buy me a coffee: %s"]):format(donate:gsub("^https?://", ""))))
  end
  layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(
    (L["Version %s"]):format(C_AddOns.GetAddOnMetadata(addonName, "Version") or "?")))

  Settings.RegisterAddOnCategory(category)
end

function ns.OpenConfig()
  if categoryID and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(categoryID)
  end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------
local function say(msg)
  print("|cffffd36eFish & Tips|r: " .. msg)
end

SLASH_FISHTIPS1 = "/fishtips"
SLASH_FISHTIPS2 = "/ft"
SlashCmdList["FISHTIPS"] = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.-)$")

  if cmd == "" then
    if ns.UI and ns.UI.Toggle then ns.UI.Toggle() end
  elseif cmd == "config" or cmd == "options" then
    ns.OpenConfig()
  elseif cmd == "theme" then
    if rest == "classic" or rest == "modern" or rest == "blend" then
      ns.SetSetting("theme", rest)
      if ns.UI and ns.UI.ApplyTheme then ns.UI.ApplyTheme(rest) end
      say((L["theme set to %s."]):format(rest))
    else
      say("theme: classic | modern | blend")
    end
  elseif cmd == "cast" then
    if rest == "off" or rest == "doubleclick" or rest == "key" or rest == "both" then
      settings.castMode = rest
      if ns.Casting and ns.Casting.ApplyMode then ns.Casting.ApplyMode() end
      say((L["cast mode: %s."]):format(rest))
    else
      say("cast: off | doubleclick | key | both")
    end
  elseif cmd == "session" then
    if rest == "manual" or rest == "idle" or rest == "zone" or rest == "zoneidle" then
      settings.sessionEnd = rest
      say((L["new sessions start: %s."]):format(rest))
    else
      say("session: manual | idle | zone | zoneidle  (currently " .. (settings.sessionEnd or "idle") .. ")")
    end
  elseif cmd == "autoloot" then
    if rest == "on" or rest == "off" then
      settings.autoLoot = (rest == "on")
      say((L["auto-loot %s."]):format(rest))
    else
      say("autoloot: on | off  (currently " .. (settings.autoLoot ~= false and "on" or "off") .. ")")
    end
  elseif cmd == "junk" then
    if rest == "on" or rest == "off" then
      settings.includeJunk = (rest == "on")
      if ns.FireRefresh then ns.FireRefresh() end
      say((L["junk items %s."]):format(rest))
    else
      say("junk: on | off  (currently " .. (settings.includeJunk ~= false and "on" or "off") .. ")")
    end
  elseif cmd == "auc" then
    if rest == "on" or rest == "off" then
      settings.auctionatorPrices = (rest == "on")
      if ns.FireRefresh then ns.FireRefresh() end
      say((L["auctionator prices %s."]):format(rest))
    else
      say("auc: on | off  (currently " .. (settings.auctionatorPrices and "on" or "off") .. ")")
    end
  elseif cmd == "castdebug" then
    ns.castDebug = not ns.castDebug
    say("cast debug " .. (ns.castDebug and "on." or "off."))
    if ns.Casting and ns.Casting.Debug then ns.Casting.Debug() end
  elseif cmd == "demo" then
    local on
    if rest == "on" then on = true
    elseif rest == "off" then on = false
    else on = not ns.demoOn end
    ns.SetSetting("demo", on)
    if ns.SetDemo then ns.SetDemo(on) end
    say("demo data " .. (on and "on." or "off."))
  else
    say("commands: /ft  (toggle)  |  config  |  cast off|doubleclick|key|both  |  session manual|idle|zone|zoneidle  |  autoloot on|off  |  junk on|off  |  auc on|off  |  demo on|off")
  end
end
