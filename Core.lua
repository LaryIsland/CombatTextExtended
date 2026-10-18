local addonName, ns = ...

-- Names of things in the addon players see or click (options, buttons, pages, commands) are marked {like this} in
-- Locales, and shown in a colour of their own: Blizzard's for links and terms in its own text. Done once every locale
-- file has loaded, so a translation's lines are marked too. Message templates players edit never go through this.
ns.NAME_COLOR = "ff71d5ff"
for key, text in pairs(ns.L) do
	if type(text) == "string" and text:find("{", 1, true) then
		rawset(ns.L, key, (text:gsub("{(.-)}", "|c" .. ns.NAME_COLOR .. "%1|r")))
	end
end

-- LibEditMode in namespace mode (embeds.xml loads its namespaced.lua first), so CTX has its own copy and never shares
-- another addon's older one through LibStub.
ns.LEM = ns.LibEditMode

-- Secret values ------------------------------------------------------------------------------------------------------
-- The client hides many values from addons in combat (design document 2.3). They can be shown (SetFormattedText,
-- BreakUpLargeNumbers) but never compared, added up, used as table keys or tested. Everything that reads a value
-- the client may hide goes through these first.

-- True for a value the client is hiding.
function ns.IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value) == true
end

-- The value when it can be read, otherwise nil.
function ns.Readable(value)
	if ns.IsSecret(value) then return nil end
	return value
end

-- True when there is a value, readable or not. A hidden value is never nil.
function ns.Present(value)
	return ns.IsSecret(value) or value ~= nil
end

-- Errors and events --------------------------------------------------------------------------------------------------

-- Errors keep the stack they happened on.
local function WithStack(err)
	return tostring(err) .. (debugstack and ("\n" .. debugstack(2)) or "")
end
ns.WithStack = WithStack

function ns.ReportError(where, err)
	geterrorhandler()(addonName .. " (" .. tostring(where) .. "): " .. tostring(err))
end

-- Calls fn safely, reporting any error with where it happened.
function ns.SafeCall(where, fn, ...)
	local ok, err = xpcall(fn, WithStack, ...)
	if not ok then ns.ReportError(where, err) end
	return ok
end

local events, unitEvents = {}, {}
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local handlers = events[event]
	if not handlers then return end
	for i = 1, #handlers do
		local ok, err = xpcall(handlers[i], WithStack, ...)
		if not ok then ns.ReportError(event, err) end
	end
end)

-- Calls handler(...) on every `event`. Any number of modules can listen to the same event.
function ns.On(event, handler)
	if not events[event] then
		events[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(events[event], handler)
end

-- As ns.On, for a unit event, only for `unit` (each unit gets a frame of its own, as RegisterUnitEvent takes one
-- registration per frame and event).
function ns.OnUnit(event, unit, handler)
	local key = event .. ":" .. unit
	local entry = unitEvents[key]
	if not entry then
		entry = { handlers = {}, frame = CreateFrame("Frame") }
		unitEvents[key] = entry
		entry.frame:SetScript("OnEvent", function(_, _, ...)
			for i = 1, #entry.handlers do
				local ok, err = xpcall(entry.handlers[i], WithStack, ...)
				if not ok then ns.ReportError(event, err) end
			end
		end)
		entry.frame:RegisterUnitEvent(event, unit)
	end
	table.insert(entry.handlers, handler)
end

-- The addon's own notifications, named in capitals (Notes/Architecture.md lists them all): DB_READY, LOGIN,
-- SETTINGS_CHANGED (what changed, nil for everything), AREAS_CHANGED, TYPES_CHANGED, EDIT_MODE (true on entering,
-- false on leaving), COMBAT (true, false) and others.
local listeners = {}
function ns.Listen(name, handler)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], handler)
end

function ns.Fire(name, ...)
	local handlers = listeners[name]
	if not handlers then return end
	for i = 1, #handlers do
		local ok, err = xpcall(handlers[i], WithStack, ...)
		if not ok then ns.ReportError(name, err) end
	end
end

-- Chat lines for the player have no addon prefix, so they're easy to skim.
-- Edit Mode's slider rows show the value to the right of the slider; CTX's (the areas' dialog and the Event Types
-- popup) put it between the name and the slider, so the slider ends where the dropdowns do. controlWidth: the
-- dropdowns' width, which the value and the slider share. Safe to call again.
local SLIDER_VALUE_WIDTH = 38
local SLIDER_REACH = 2 -- the slider's arrow art stops short of its frame, so it reaches this far past the dropdowns
local LABEL_GAP = 5 -- Edit Mode's gap between a row's name and its control
ns.SLIDER_VALUE_WIDTH = SLIDER_VALUE_WIDTH
function ns.ValueBeforeSlider(row, controlWidth)
	local slider = row.Slider
	local value = slider and slider.RightText
	if not (value and row.Label) then return end
	value:ClearAllPoints()
	value:SetPoint("LEFT", row.Label, "RIGHT", LABEL_GAP, 0)
	value:SetWidth(SLIDER_VALUE_WIDTH)
	value:SetJustifyH("CENTER")
	slider:ClearAllPoints()
	slider:SetPoint("LEFT", value, "RIGHT", 0, 0)
	slider:SetWidth(controlWidth - SLIDER_VALUE_WIDTH + SLIDER_REACH)
end

-- The translucent dialog border's background (inset 7) shows a little past the metal frame's edges in Forever; moved
-- in so it stays inside (the areas' dialog and the Event Types popup).
local BACKGROUND_INSET = 9
function ns.TuckBackground(border)
	local background = border and rawget(border, "Bg")
	if not background then return end
	background:ClearAllPoints()
	background:SetPoint("TOPLEFT", BACKGROUND_INSET, -BACKGROUND_INSET)
	background:SetPoint("BOTTOMRIGHT", -BACKGROUND_INSET, BACKGROUND_INSET)
end

function ns.Print(text)
	DEFAULT_CHAT_FRAME:AddMessage(text)
end

function ns.InCombat()
	return InCombatLockdown() == true
end

-- The game's own settings ---------------------------------------------------------------------------------------------
-- Blizzard's combat text switches (design document 2.2 and 2.5) decide which kinds of text show. Read through a cache
-- that CVAR_UPDATE keeps current, as some are checked for every line of text.

local cvarCache = {}
function ns.GameSetting(name)
	local value = cvarCache[name]
	if value == nil then
		value = C_CVar.GetCVarBool(name) == true
		cvarCache[name] = value
	end
	return value
end

-- The game's labels for its Text on Me switches (Blizzard_SettingsDefinitions_Frame/Mainline/CombatOverrides.lua), so
-- CTX names a switch the way the game's options do. ns.GameSettingLabel(cvar): the label, or nil.
local GAME_SETTING_LABELS = {
	floatingCombatTextDodgeParryMiss_v2 = "COMBAT_TEXT_SHOW_DODGE_PARRY_MISS_TEXT",
	floatingCombatTextDamageReduction_v2 = "COMBAT_TEXT_SHOW_RESISTANCES_TEXT",
	floatingCombatTextRepChanges_v2 = "COMBAT_TEXT_SHOW_REPUTATION_TEXT",
	floatingCombatTextReactives_v2 = "COMBAT_TEXT_SHOW_REACTIVES_TEXT",
	floatingCombatTextFriendlyHealers_v2 = "COMBAT_TEXT_SHOW_FRIENDLY_NAMES_TEXT",
	floatingCombatTextCombatState_v2 = "COMBAT_TEXT_SHOW_COMBAT_STATE_TEXT",
	floatingCombatTextCombatHealingAbsorbSelf_v2 = "SHOW_COMBAT_HEALING_ABSORB_SELF",
	floatingCombatTextComboPoints_v2 = "COMBAT_TEXT_SHOW_COMBO_POINTS_TEXT",
	floatingCombatTextLowManaHealth_v2 = "COMBAT_TEXT_SHOW_LOW_HEALTH_MANA_TEXT",
	floatingCombatTextEnergyGains_v2 = "COMBAT_TEXT_SHOW_ENERGIZE_TEXT",
	floatingCombatTextPeriodicEnergyGains_v2 = "COMBAT_TEXT_SHOW_PERIODIC_ENERGIZE_TEXT",
	floatingCombatTextHonorGains_v2 = "COMBAT_TEXT_SHOW_HONOR_GAINED_TEXT",
	floatingCombatTextAuras_v2 = "COMBAT_TEXT_SHOW_AURAS_TEXT",
}

function ns.GameSettingLabel(name)
	local label = GAME_SETTING_LABELS[name] and _G[GAME_SETTING_LABELS[name]]
	return type(label) == "string" and label or nil
end

-- Changes one of the game's settings. Only ever called because the player clicked something that says it changes the
-- game's own setting.
function ns.SetGameSetting(name, on)
	C_CVar.SetCVar(name, on and "1" or "0")
	cvarCache[name] = nil
	ns.Fire("GAME_SETTING_CHANGED", name)
end

ns.On("CVAR_UPDATE", function(name)
	if type(name) == "string" then
		cvarCache[name] = nil
		ns.Fire("GAME_SETTING_CHANGED", name)
	end
end)

-- Saved settings ------------------------------------------------------------------------------------------------------
-- Everything players set is in AceDB profiles, which every character starts out sharing ("Default", or the profile
-- picked as the default for new characters). The profile's defaults (ns.PROFILE_DEFAULTS) are built in Presets.lua
-- from the event types and triggers in Catalogue.lua. Areas aren't defaults: players add and delete them, so they're
-- written into the profile from ns.DEFAULT_AREAS whenever a profile has none (a new or reset profile).
--   ns.db       the AceDB object
--   ns.profile  the current profile
--   ns.global   account-wide: the default profile for new characters, the probe's findings

local function EnsureAreas()
	local profile = ns.profile
	if not profile.areas or next(profile.areas) == nil then
		ns.ApplyPresetAreas(profile)
	end
end

function ns.ProfileChanged()
	ns.profile = ns.db.profile
	EnsureAreas()
	ns.Fire("SETTINGS_CHANGED")
	ns.Fire("AREAS_CHANGED")
	ns.Fire("TYPES_CHANGED")
end

-- Records a change to the current profile and tells the modules (what: a short name of the setting, for listeners
-- that only care about some).
function ns.Changed(what)
	ns.Fire("SETTINGS_CHANGED", what)
end

ns.On("ADDON_LOADED", function(name)
	if name ~= addonName then return end
	local saved = _G.CombatTextExtendedDB
	local defaultProfile = type(saved) == "table" and type(saved.global) == "table" and saved.global.defaultProfile
	local db = LibStub("AceDB-3.0"):New("CombatTextExtendedDB", {
		profile = ns.PROFILE_DEFAULTS,
		global = { defaultProfile = "Default", fctPromptAfter = 0, probe = {} },
	}, type(defaultProfile) == "string" and defaultProfile or true)
	ns.db = db
	ns.global = db.global
	for _, callback in ipairs({ "OnProfileChanged", "OnProfileCopied", "OnProfileReset" }) do
		db.RegisterCallback(ns, callback, ns.ProfileChanged)
	end
	ns.profile = db.profile
	EnsureAreas()
	ns.Fire("DB_READY")
end)

ns.On("PLAYER_LOGIN", function()
	ns.Fire("LOGIN")
end)

ns.On("PLAYER_REGEN_DISABLED", function() ns.Fire("COMBAT", true) end)
ns.On("PLAYER_REGEN_ENABLED", function() ns.Fire("COMBAT", false) end)
