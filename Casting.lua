local _, ns = ...

-- Casting.lua -- cast triggers for Fishing. Mechanism (worked out against the 12.0
-- secure-binding APIs):
--   * Cast Fishing through the SECURE BINDING SYSTEM **by name** (`SetOverrideBindingSpell`),
--     which resolves the profession spell exactly like the `/cast Fishing` macro that works.
--     `type="spell"` (CastSpellByID/Name) and `type="macro"` (macrotext) BOTH silently no-op for
--     this spell on this build -- verified in-game -- so we do not use a secure action button.
--   * Detect the double-right-click via the **GLOBAL_MOUSE_DOWN event**, NOT
--     `WorldFrame:HookScript` (hooking the world frame taints the secure cast, which then no-ops).
-- Two paths, each gated by `castMode` (off / doubleclick / key / both):
--   * keybind            -- the player's bound key (Bindings.xml) is override-bound to cast by name.
--   * double-right-click -- two quick right-downs arm a one-shot BUTTON2 override that casts on the
--                           second release, then clears. `castDelay` is the double-click window.
ns.Casting = ns.Casting or {}

-- Bindings.xml binding label. Its body re-applies the keybind override (self-heal). _G[...] so
-- luacheck ignores these global writes.
_G.BINDING_NAME_FISHTIPSCAST = ns.L["Cast Fishing"]

local DOUBLE_MIN = 0.04  -- ignore right-clicks closer together than this (debounce)

-- ---------------------------------------------------------------------------
-- Settings helpers
-- ---------------------------------------------------------------------------
local function mode()
  local s = ns.GetSettings and ns.GetSettings()
  return (s and s.castMode) or "off"
end

local function delay()
  local s = ns.GetSettings and ns.GetSettings()
  return (s and s.castDelay) or 0.3
end

local function keyEnabled() local m = mode(); return m == "key" or m == "both" end
local function doubleEnabled() local m = mode(); return m == "doubleclick" or m == "both" end

-- The localized Fishing name comes from the single resolver in Core.lua
-- (ns.FishingSpellName -- shared with catch detection, memoized on success only).
-- SetOverrideBindingSpell casts by this name, like `/cast Fishing`.
local function fishingName()
  return ns.FishingSpellName()
end

-- ---------------------------------------------------------------------------
-- Override-binding owners. Keybind override is persistent (while enabled); the double-click
-- override is transient (armed for one click). Separate owners so clearing one never disturbs the
-- other.
-- ---------------------------------------------------------------------------
local keyOwner = CreateFrame("Frame")
local dblOwner = CreateFrame("Frame")

local function clearDouble()
  if not InCombatLockdown() then ClearOverrideBindings(dblOwner) end
end

-- Bind the player's "Cast Fishing" key(s) to cast Fishing by name. Reapplied on login / mode change
-- / combat-end, and by the Bindings.xml body if it was ever cleared.
local function applyKeyOverride()
  if InCombatLockdown() then return end
  ClearOverrideBindings(keyOwner)
  if not keyEnabled() then return end
  local name = fishingName()
  local k1, k2 = GetBindingKey("FISHTIPSCAST")
  if k1 then SetOverrideBindingSpell(keyOwner, true, k1, name) end
  if k2 then SetOverrideBindingSpell(keyOwner, true, k2, name) end
end

_G.FishTips_RunKeybind = function() applyKeyOverride() end

-- ---------------------------------------------------------------------------
-- Double-right-click: time two quick right-downs (GLOBAL_MOUSE_DOWN, non-consuming so camera /
-- hover are untouched); on the second, arm a one-shot BUTTON2 override that casts on that click's
-- release, then self-clears shortly after.
-- ---------------------------------------------------------------------------
local prevDown, lastCast = 0, 0
local function onGlobalMouseDown(button)
  if button ~= "RightButton" or not doubleEnabled() or InCombatLockdown() then return end
  if IsMouseButtonDown("LeftButton") then return end                       -- not a both-button move
  if GetNumLootItems and GetNumLootItems() ~= 0 then return end            -- don't fire over loot
  local now = GetTime()
  if now - lastCast < 0.5 then return end                                  -- debounce after a cast
  local diff = now - prevDown
  if diff >= DOUBLE_MIN and diff <= delay() then
    SetOverrideBindingSpell(dblOwner, true, "BUTTON2", fishingName())      -- 2nd release casts
    lastCast = now
    prevDown = 0
    if C_Timer and C_Timer.After then C_Timer.After(delay() + 0.25, clearDouble) end
    if ns.castDebug then print("|cffffd36eFish & Tips|r: double-click armed -> /cast " .. fishingName()) end
  else
    prevDown = now
  end
end

-- ---------------------------------------------------------------------------
-- Apply the current cast mode. Out of combat (login / dropdown change / combat-end), taint-free.
-- ---------------------------------------------------------------------------
function ns.Casting.ApplyMode()
  applyKeyOverride()
  clearDouble()
end

-- Dev diagnostic (/ft castdebug): dump the live cast state.
function ns.Casting.Debug()
  local k1, k2 = GetBindingKey("FISHTIPSCAST")
  print("|cffffd36eFish & Tips|r cast debug:")
  print(string.format("  mode=%s  key=%s  double=%s  delay=%.2f",
    mode(), tostring(keyEnabled()), tostring(doubleEnabled()), delay()))
  print(string.format("  cast = /cast %s (via SetOverrideBindingSpell)", tostring(fishingName())))
  print(string.format("  keybind keys = %s , %s", tostring(k1), tostring(k2)))
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("GLOBAL_MOUSE_DOWN")
f:SetScript("OnEvent", function(_, event, arg1)
  if event == "GLOBAL_MOUSE_DOWN" then
    onGlobalMouseDown(arg1)
  else
    ns.Casting.ApplyMode()
  end
end)
