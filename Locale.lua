local _, ns = ...

-- Locale.lua -- the string-table mechanism. Loaded FIRST (see FishTips.toc); the locale
-- files (Locales/enUS.lua, then any translation) load right after it, before Core.lua.
--
-- Every piece of text the addon displays is a symbolic key (L.OPT_AUTO_LOOT) defined in
-- Locales/enUS.lua, the base locale. A translation is one more Locales/<code>.lua that
-- registers its own table and assigns the keys it covers; whatever it leaves out stays
-- English. Code reads the table only as L.KEY, never L[expr], so the test suite can
-- check by a plain source scan that every key read is defined and every key defined is
-- read.
--
-- Which language is shown, in priority order:
--   1. a locale set explicitly (ns.SetLocale -- the dev command /ft locale <code>),
--   2. the game client's language, when a translation for it is registered,
--   3. enUS.
-- Locale files do NOT gate themselves on GetLocale(): saved settings (where an explicit
-- choice lives) don't exist yet while files load, so the choice is made here, centrally,
-- and can change once they do.
--
-- Only display text is localized. Nothing stored is: DB keys, saved names and links,
-- setting values, and slash tokens are the same in every language.

local BASE = "enUS"
local clientCode = GetLocale and GetLocale() or BASE

local locales = {}    -- code -> { KEY = "text" }, filled by the Locales/ files
ns.locales = locales

local chosen          -- priority 1: the explicitly set code (nil => follow the client)
local activeCode = BASE
local active          -- the active translation's table; nil while English is active
local listeners = {}

local function resolve()
  local code = (chosen and locales[chosen] and chosen)
    or (locales[clientCode] and clientCode)
    or BASE
  if code == activeCode then return end
  activeCode = code
  active = (code ~= BASE) and locales[code] or nil
  for i = 1, #listeners do listeners[i]() end
end

-- The table every file reads. A lookup tries the active translation, then the base
-- locale, and finally hands back the key's own name -- so a missing translation falls
-- back to English one string at a time, and a typo'd key shows up as visible ALL_CAPS
-- text instead of an error thrown from inside a render.
ns.L = setmetatable({}, { __index = function(_, key)
  local value = active and active[key]
  if type(value) ~= "string" then
    local base = locales[BASE]
    value = base and base[key]
  end
  if type(value) ~= "string" then return key end
  return value
end })

-- Called by a locale file: returns the string table to fill for `code`. Several client
-- codes may share one translation (ns.NewLocale("esES", "esMX")).
function ns.NewLocale(...)
  local strings
  for i = 1, select("#", ...) do
    local code = select(i, ...)
    strings = strings or locales[code] or {}
    locales[code] = strings
  end
  resolve()
  return strings
end

-- Set the explicit choice (priority 1) to a registered code, or clear it with nil.
-- An unregistered code changes nothing and returns false -- a stale saved choice must
-- never break the text. Labels built once (the options panel, the window's buttons)
-- keep the language they were built in, which is why /ft locale asks for a /reload.
function ns.SetLocale(code)
  if code ~= nil and not locales[code] then return false end
  chosen = code
  resolve()
  return true
end

function ns.GetLocaleCode()
  return activeCode
end

-- The registered codes, sorted (for /ft locale).
function ns.GetLocaleCodes()
  local list = {}
  for code in pairs(locales) do list[#list + 1] = code end
  table.sort(list)
  return list
end

-- Runs `fn` now and again whenever the active locale changes -- for the few strings
-- that are handed to the game at file load, before a saved choice can apply.
function ns.OnLocale(fn)
  listeners[#listeners + 1] = fn
  fn()
end

-- A count with its noun: ns.Plural(n, L.CASTS_ONE, L.CASTS_MANY) -> "3 casts". The
-- singular string is used for exactly 1. A language with other plural rules writes the
-- game's own plural escape inside the value ("%d |4cast:casts;"), which the client
-- resolves when it draws the text.
function ns.Plural(n, one, many)
  return (n == 1 and one or many):format(n)
end

-- An integer with the active locale's thousands separator: 1234567 -> "1,234,567".
function ns.FormatNumber(n)
  n = n or 0
  local s = tostring(math.floor(n + 0.5))
  local sign, digits = s:match("^(%-?)(%d+)$")
  if not digits then return s end
  local sep = ns.L.THOUSANDS_SEPARATOR
  if sep == "" then return s end
  local count
  repeat
    digits, count = digits:gsub("^(%d+)(%d%d%d)", function(head, tail) return head .. sep .. tail end)
  until count == 0
  return sign .. digits
end
