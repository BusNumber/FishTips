local _, ns = ...

-- Locale.lua -- localization scaffold. Loaded FIRST (see FishTips.toc) so every other
-- file can reference ns.L at load time.
--
-- English keys ARE the defaults: ns.L[key] falls back to the key itself, so there is no
-- enUS table and a missing translation can never break a render. User-facing strings go
-- through ns.L["..."]; the English string is the key. Format strings are wrapped WHOLE
-- (e.g. ns.L["+%d more"]) so translations can reorder the words.
--
-- Adding a locale: overwrite keys under a GetLocale() branch, e.g.
--
--   if GetLocale() == "frFR" then
--     local L = ns.L
--     L["Warband"] = "..."
--     L["Top zones"] = "..."
--   end

ns.L = setmetatable({}, { __index = function(_, k) return k end })
