std = "lua51"
max_line_length = false

-- Globals this addon defines (SavedVariable + slash bindings).
globals = {
  "FishTipsDB",
  "SLASH_FISHTIPS1",
  "SLASH_FISHTIPS2",
  "SlashCmdList",  -- we assign SlashCmdList["FISHTIPS"]
  "StaticPopupDialogs",  -- we register StaticPopupDialogs["FISHTIPS_RESET_SESSION"]
}

-- WoW API surface we read. These don't exist outside the game client, so only
-- syntax/lint checks are meaningful locally (see CONTRIBUTING.md).
read_globals = {
  "CreateFrame", "UIParent", "Minimap", "WorldFrame",
  "GetTime", "GetCursorPosition", "InCombatLockdown", "C_Timer",
  "SetOverrideBindingClick", "SetOverrideBindingSpell", "ClearOverrideBindings",
  "GetBindingKey", "IsMouseButtonDown",
  "GetRealZoneText", "GetSubZoneText", "UnitName", "GetNormalizedRealmName",
  "C_Map", "C_AddOns", "C_Spell", "GetSpellInfo",
  "GetNumLootItems", "GetLootSlotLink", "GetLootSlotInfo", "GetItemInfoInstant", "LootSlot",
  "IsFishingLoot",
  "ITEM_QUALITY_COLORS", "STANDARD_TEXT_FONT", "UNKNOWN",
  "Settings", "GameTooltip", "StaticPopup_Show", "YES", "NO",
  "CreateSettingsListSectionHeaderInitializer", "MinimalSliderWithSteppersMixin",
  "Auctionator",  -- Auctionator's public v1 API, present only if installed
}
