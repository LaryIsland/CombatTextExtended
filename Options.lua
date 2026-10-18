local addonName, ns = ...
local L = ns.L

-- Options > AddOns > Combat Text Extended (design document 4.2), built with Blizzard's own Settings API so it looks
-- and works like the game's own pages: everything that isn't an area's (areas are set up in Edit Mode, event types in
-- the Event Types popup), the game's own combat text switches (4.3), cooldowns, presets, and a Profiles subpage.
--
-- Every control is a proxy setting reading and writing the current profile, so switching profiles only needs the
-- controls told to read again. The game's own settings are read and set as the game's (they change only when
-- clicked), and have no default, so the panel's Defaults button never changes a game setting. Nothing changes in
-- combat.
--   ns.Options.Open(subpage)   opens the page, or its Profiles subpage with "profiles"

ns.Options = {}
local Options = ns.Options

local TITLE = "Combat Text Extended"
local VARIABLE_PREFIX = "COMBATTEXTEXTENDED_"
local POPUP_PREFIX = "COMBATTEXTEXTENDED_"
local NAME_LETTERS = 32                 -- longest profile name, as Better Personal Resource Display allows
local EXPORT_PREFIX = "CTX1:"           -- export format version (design document 4.2)
local GAME_FCT = "enableFloatingCombatText"

local category, profilesCategory
local registered = {}                   -- every setting on CTX's pages, told to read again together
local shown = {}                        -- [setting] = the value its control shows
local popups = {}                       -- every popup's name, hidden when combat starts

-- Refusing in combat --------------------------------------------------------------------------------------------------

local function ErrorText(text)
	if UIErrorsFrame and UIErrorsFrame.AddExternalErrorMessage then
		UIErrorsFrame:AddExternalErrorMessage(text)
	else
		ns.Print(text)
	end
end

local function RefuseInCombat()
	if not ns.InCombat() then return false end
	ErrorText(ERR_NOT_IN_COMBAT or L.OPT_IN_COMBAT)
	return true
end

-- Controls read their setting again --------------------------------------------------------------------------------
-- After a profile change, a refused change or a game setting changed elsewhere. At most once a frame.

-- Only controls whose value differs from what they show are told: telling a checkbox replays its click sound.
-- Greying (modify predicates) is checked again on every visible control, as the game only does it when a control is
-- first shown or its parent changes.

local refreshQueued = false
local function RefreshNow()
	refreshQueued = false
	for _, setting in ipairs(registered) do
		local ok, value = pcall(setting.GetValue, setting)
		if ok and value ~= shown[setting] then
			shown[setting] = value
			ns.SafeCall("Options refresh", setting.NotifyUpdate, setting)
		end
	end
	local list = SettingsPanel and SettingsPanel:IsShown() and SettingsPanel:GetSettingsList()
	if list and list.ScrollBox then
		list.ScrollBox:ForEachFrame(function(frame)
			if frame.EvaluateState then ns.SafeCall("Options refresh", frame.EvaluateState, frame) end
		end)
	end
end

local function RefreshSoon()
	if refreshQueued or not category then return end
	refreshQueued = true
	C_Timer.After(0, RefreshNow)
end

-- Settings ------------------------------------------------------------------------------------------------------------

local function Register(where, variable, varType, name, default, get, set)
	local setting
	setting = Settings.RegisterProxySetting(where, VARIABLE_PREFIX .. variable, varType, name, default, get,
		function(value)
			shown[setting] = value -- the control now shows what was picked, whether or not it's kept
			set(value)
		end)
	registered[#registered + 1] = setting
	local ok, value = pcall(get)
	if ok then shown[setting] = value end
	return setting
end

local function Default(field)
	return ns.PROFILE_DEFAULTS and ns.PROFILE_DEFAULTS[field]
end

-- A setting for one field of the profile. toControl/fromControl turn a saved value into the control's type and back
-- (the Settings API wants one type per setting, so a font of false is "" in its dropdown).
local function ProfileSetting(where, field, varType, name, toControl, fromControl)
	local default = Default(field)
	if toControl then default = toControl(default) end
	local function Get()
		local value = ns.profile and ns.profile[field]
		if toControl then return toControl(value) end
		return value
	end
	local function Set(value)
		if not ns.profile or RefuseInCombat() then
			RefreshSoon()
			return
		end
		if fromControl then value = fromControl(value) end
		ns.profile[field] = value
		ns.Changed(field)
	end
	return Register(where, field, varType, name, default, Get, Set)
end

local function OwnSelectionText() return nil end -- nil: the dropdown shows its selected choice

-- The settings list reuses a dropdown frame for the next dropdown shown, and only sets the text function when the new
-- one has one (SettingsDropdownControlMixin:InitDropdown), so every CTX dropdown sets one, and takes it off again when
-- the list lets the frame go (its element resetter calls the initializer's Resetter); otherwise the game's and other
-- addons' dropdowns would show CTX's text.
local function SelectionText(initializer, func)
	initializer.getSelectionTextFunc = func
	local reset = initializer.Resetter
	initializer.Resetter = function(self, frame)
		if reset then reset(self, frame) end
		local dropdown = frame and frame.Control and frame.Control.Dropdown
		if dropdown and dropdown.SetSelectionText then dropdown:SetSelectionText(nil) end
	end
end

local function Dropdown(where, setting, options, tooltip)
	local initializer = Settings.CreateDropdown(where, setting, options, tooltip)
	SelectionText(initializer, OwnSelectionText)
	return initializer
end

local function Choices(list)
	return function()
		local container = Settings.CreateControlTextContainer()
		for _, choice in ipairs(list()) do
			container:Add(choice.value, choice.text, choice.tooltip)
		end
		return container:GetData()
	end
end

local function Header(layout, name, tooltip)
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(name, tooltip))
end

-- A button row. With a name it reads like the other rows, label on the left; with "" it has no label of its own and
-- lines up with the other labels, as Blizzard's Open Edit Mode button on its Cooldown Manager options (those get no
-- tooltip, which would start with the empty name).
local function Button(layout, name, text, click, tooltip)
	local initializer = CreateSettingsButtonInitializer(name, text, click, tooltip, true)
	layout:AddInitializer(initializer)
	return initializer
end

-- Opening other windows from the page closes it first, as Blizzard's own Open Edit Mode button does
-- (AdvancedOptions.lua), so nothing opens behind it.
local function CloseSettingsPanel()
	if SettingsPanel and SettingsPanel:IsShown() then
		SettingsPanel:Close(true)
	end
end

-- The root page -------------------------------------------------------------------------------------------------------

local function OpenEditMode()
	if not (ns.EditMode and ns.EditMode.Open) then return end
	-- Only close the page when Edit Mode will open; otherwise Open says why it can't.
	if not ns.InCombat() and EditModeManagerFrame and EditModeManagerFrame:CanEnterEditMode() then
		CloseSettingsPanel()
	end
	ns.EditMode.Open()
end

local function FontChoices()
	local list = {}
	local fonts = ns.Media and ns.Media.Fonts and ns.Media.Fonts() or {}
	for _, font in ipairs(fonts) do
		list[#list + 1] = { value = font.value or "", text = font.text }
	end
	return list
end

-- Each number format with what 12345 looks like in it.
local SAMPLE_NUMBER = 12345
local function NumberChoices()
	local grouped = BreakUpLargeNumbers and BreakUpLargeNumbers(SAMPLE_NUMBER) or "12,345"
	local short = AbbreviateNumbers and AbbreviateNumbers(SAMPLE_NUMBER) or "12K"
	return {
		{ value = "full", text = L.OPT_NUMBERS_FULL:format(SAMPLE_NUMBER) },
		{ value = "grouped", text = L.OPT_NUMBERS_GROUPED:format(grouped) },
		{ value = "short", text = L.OPT_NUMBERS_SHORT:format(short) },
	}
end

local function OutlineChoices()
	return {
		{ value = "", text = L.OPT_OUTLINE_NONE },
		{ value = "OUTLINE", text = L.OPT_OUTLINE_THIN },
		{ value = "THICKOUTLINE", text = L.OPT_OUTLINE_THICK },
	}
end

-- The game's own combat text settings (design document 4.3), with Blizzard's own labels and tooltips. Text on Target
-- is drawn by the game over targets; CTX can only switch it.
-- The game's Text on Me switches, as its own Combat options list them (CombatOverrides.lua): label, tooltip, setting.
local TEXT_ON_ME = {
	{ "COMBAT_TEXT_SHOW_DODGE_PARRY_MISS_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_DODGE_PARRY_MISS",
		"floatingCombatTextDodgeParryMiss_v2" },
	{ "COMBAT_TEXT_SHOW_RESISTANCES_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_RESISTANCES",
		"floatingCombatTextDamageReduction_v2" },
	{ "COMBAT_TEXT_SHOW_REPUTATION_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_REPUTATION", "floatingCombatTextRepChanges_v2" },
	{ "COMBAT_TEXT_SHOW_REACTIVES_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_REACTIVES", "floatingCombatTextReactives_v2" },
	{ "COMBAT_TEXT_SHOW_FRIENDLY_NAMES_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_FRIENDLY_NAMES",
		"floatingCombatTextFriendlyHealers_v2" },
	{ "COMBAT_TEXT_SHOW_COMBAT_STATE_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_COMBAT_STATE",
		"floatingCombatTextCombatState_v2" },
	{ "SHOW_COMBAT_HEALING_ABSORB_SELF", "OPTION_TOOLTIP_SHOW_COMBAT_HEALING_ABSORB_SELF",
		"floatingCombatTextCombatHealingAbsorbSelf_v2" },
	{ "COMBAT_TEXT_SHOW_COMBO_POINTS_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_COMBO_POINTS",
		"floatingCombatTextComboPoints_v2" },
	{ "COMBAT_TEXT_SHOW_LOW_HEALTH_MANA_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_LOW_HEALTH_MANA",
		"floatingCombatTextLowManaHealth_v2" },
	{ "COMBAT_TEXT_SHOW_ENERGIZE_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_ENERGIZE", "floatingCombatTextEnergyGains_v2" },
	{ "COMBAT_TEXT_SHOW_PERIODIC_ENERGIZE_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_PERIODIC_ENERGIZE",
		"floatingCombatTextPeriodicEnergyGains_v2" },
	{ "COMBAT_TEXT_SHOW_HONOR_GAINED_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_HONOR_GAINED",
		"floatingCombatTextHonorGains_v2" },
	{ "COMBAT_TEXT_SHOW_AURAS_TEXT", "OPTION_TOOLTIP_COMBAT_TEXT_SHOW_AURAS", "floatingCombatTextAuras_v2" },
}

local function GlobalText(name, fallback)
	local text = name and _G[name]
	return type(text) == "string" and text or fallback
end

local function GameSettingTooltip(blizzardTip, extra)
	return function()
		local lines = {}
		local tip = GlobalText(blizzardTip)
		if tip then lines[#lines + 1] = tip end
		if extra then lines[#lines + 1] = extra end
		lines[#lines + 1] = L.OPT_GAME_SETTING_TIP
		return table.concat(lines, "\n\n")
	end
end

-- Sets one of the game's settings, which may be protected (beta check 18). If the game didn't take it, says where the
-- player can change it, and the checkbox goes back to what the game has.
local function SetGameSetting(cvar, label, on)
	if RefuseInCombat() then
		RefreshSoon()
		return
	end
	pcall(ns.SetGameSetting, cvar, on)
	if C_CVar.GetCVarBool(cvar) ~= on then
		ns.Print(L.OPT_GAME_SETTING_FAILED:format(label))
	end
	RefreshSoon()
end

local function GameCheckbox(cvar, label, tooltip)
	local setting = Register(category, "GAME_" .. cvar, Settings.VarType.Boolean, label, Settings.CannotDefault,
		function() return C_CVar.GetCVarBool(cvar) == true end,
		function(value) SetGameSetting(cvar, label, value) end)
	return Settings.CreateCheckbox(category, setting, tooltip)
end

-- Text on Me: one dropdown of checkboxes, its value a mask of the switches (as the game's).
local function TextOnMe(parent, modifiable)
	local function Get()
		local mask = 0
		for index, entry in ipairs(TEXT_ON_ME) do
			if C_CVar.GetCVarBool(entry[3]) then mask = bit.bor(mask, bit.lshift(1, index - 1)) end
		end
		return mask
	end
	local function Set(mask)
		for index, entry in ipairs(TEXT_ON_ME) do
			local on = bit.band(mask, bit.lshift(1, index - 1)) ~= 0
			if C_CVar.GetCVarBool(entry[3]) ~= on then SetGameSetting(entry[3], GlobalText(entry[1], entry[3]), on) end
		end
	end
	local function Options()
		local container = Settings.CreateControlTextContainer()
		for index, entry in ipairs(TEXT_ON_ME) do
			local option = container:AddCheckbox(index, GlobalText(entry[1], entry[3]), GlobalText(entry[2]))
			option.displayCheckboxTooltip = true
		end
		return container:GetData()
	end
	local label = GlobalText("FLOATING_COMBAT_TEXT_ON_ME_DROPDOWN_LABEL", L.OPT_TEXT_ON_ME)
	local setting = Register(category, "GAME_TEXT_ON_ME", Settings.VarType.Number, "", Settings.CannotDefault, Get, Set)
	local initializer = Settings.CreateDropdown(category, setting, Options)
	initializer:SetParentInitializer(parent, modifiable)
	SelectionText(initializer, function() return label end)
	initializer.noTooltip = true
	return initializer
end

-- Text on Target: the game's own menu, built the same way (checkboxes, and On/Off choices under a title).
local function TextOnTarget(parent, modifiable)
	local setting = Register(category, "GAME_TEXT_ON_TARGET", Settings.VarType.Number, "", Settings.CannotDefault,
		function() return 0 end, function() end)
	local initializer = Settings.CreateDropdown(category, setting, function() return {} end)
	initializer.customMenuGenerator = function(_, root)
		local function IsRadioSelected(data) return C_CVar.GetCVarBool(data.cvar) == data.value end
		local function SetRadioSelected(data)
			SetGameSetting(data.cvar, data.label, data.value)
			return MenuResponse.Refresh
		end
		local function IsChecked(data) return C_CVar.GetCVarBool(data.cvar) == true end
		local function SetChecked(data)
			SetGameSetting(data.cvar, data.label, not C_CVar.GetCVarBool(data.cvar))
			return MenuResponse.Refresh
		end
		local function SelectorInitializer(frame) frame.leftTexture1:SetPoint("LEFT", frame, "LEFT", 4, 0) end
		local function TitleInitializer(frame) frame.fontString:SetPoint("LEFT", frame, "LEFT", 4, 0) end
		local on, off = GlobalText("TEXT_ON_TARGET_ON_LABEL", L.OPT_ON), GlobalText("TEXT_ON_TARGET_OFF_LABEL", L.OPT_OFF)
		local function Box(labelName, cvar)
			local label = GlobalText(labelName, cvar)
			root:CreateCheckbox(label, IsChecked, SetChecked, { cvar = cvar, label = label })
				:AddInitializer(SelectorInitializer)
		end
		local function OnOff(titleName, cvar)
			local title = GlobalText(titleName, cvar)
			root:CreateDivider()
			root:CreateTitle(title):AddInitializer(TitleInitializer)
			root:CreateRadio(on, IsRadioSelected, SetRadioSelected, { cvar = cvar, value = true, label = title })
				:AddInitializer(SelectorInitializer)
			root:CreateRadio(off, IsRadioSelected, SetRadioSelected, { cvar = cvar, value = false, label = title })
				:AddInitializer(SelectorInitializer)
		end
		Box("SHOW_DAMAGE_TEXT", "floatingCombatTextCombatDamage_v2")
		OnOff("LOG_PERIODIC_EFFECTS", "floatingCombatTextCombatLogPeriodicSpells_v2")
		root:CreateSpacer(17)
		Box("SHOW_COMBAT_HEALING", "floatingCombatTextCombatHealing_v2")
		OnOff("SHOW_COMBAT_HEALING_ABSORB_TARGET", "floatingCombatTextCombatHealingAbsorbTarget_v2")
		root:CreateSpacer(17)
		Box("SHOW_TARGET_EFFECTS", "floatingCombatTextSpellMechanics_v2")
		OnOff("SHOW_OTHER_TARGET_EFFECTS", "floatingCombatTextSpellMechanicsOther_v2")
	end
	local label = GlobalText("FLOATING_COMBAT_TEXT_ON_TARGET_DROPDOWN_LABEL", L.OPT_TEXT_ON_TARGET)
	initializer:SetParentInitializer(parent, modifiable)
	SelectionText(initializer, function() return label end)
	initializer.noTooltip = true
	return initializer
end

local function CooldownChoices()
	return {
		{ value = "cdm", text = L.OPT_COOLDOWN_SOURCE_CDM, tooltip = L.OPT_COOLDOWN_SOURCE_CDM_TIP },
		{ value = "all", text = L.OPT_COOLDOWN_SOURCE_ALL, tooltip = L.OPT_COOLDOWN_SOURCE_ALL_TIP },
	}
end

local function CooldownSetting(field, varType, name)
	local defaults = Default("cooldowns")
	local function Get()
		local cooldowns = ns.profile and ns.profile.cooldowns
		return cooldowns and cooldowns[field]
	end
	local function Set(value)
		if not (ns.profile and ns.profile.cooldowns) or RefuseInCombat() then
			RefreshSoon()
			return
		end
		ns.profile.cooldowns[field] = value
		ns.Changed("cooldowns")
		RefreshSoon() -- the minimum greys out or back in with the source
	end
	return Register(category, "COOLDOWNS_" .. field, varType, name, defaults and defaults[field], Get, Set)
end

-- The minimum only applies when every spell is followed: chosen, or because the Cooldown Manager is off.
local function MinimumApplies()
	local cooldowns = ns.profile and ns.profile.cooldowns
	return not cooldowns or cooldowns.source == "all" or not C_CVar.GetCVarBool("cooldownViewerEnabled")
end

local function PresetPopup(preset)
	if RefuseInCombat() then return end
	StaticPopup_Show(POPUP_PREFIX .. "PRESET", preset.label, nil, preset.key)
end

-- Icon zoom: the slider's value is shown with an example icon, one of the player's tracked spells (else Auto Attack),
-- cropped as lines crop it, drawn into the value's text so it needs no frame of its own.
local EXAMPLE_SPELL = 6603
local EXAMPLE_SIZE = 64
local EXAMPLE_X = 44 -- from the value's left edge, past its widest ("50%"), so the icon never moves
local exampleIcon -- on the Zoom row while it's shown

local function ExampleTexture()
	local texture
	if ns.Cooldowns and ns.Cooldowns.SampleSpell then texture = select(2, ns.Cooldowns.SampleSpell(true)) end
	if not texture and C_Spell and C_Spell.GetSpellTexture then
		texture = ns.Readable(C_Spell.GetSpellTexture(EXAMPLE_SPELL))
	end
	return texture or 134400
end

local function Zoom()
	local zoom = tonumber((ns.profile or {}).iconZoom)
	return zoom or Default("iconZoom") or 16
end

local function UpdateExample(value)
	if not exampleIcon then return end
	local crop = math.min(math.max(value or Zoom(), 0), 90) / 200
	exampleIcon:SetTexture(ExampleTexture())
	exampleIcon:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
end

local function ZoomLabel(value)
	UpdateExample(value)
	return L.OPT_ICON_ZOOM_VALUE:format(value)
end

-- The example icon: a texture on the Zoom row, after the value at a fixed place. The row's frame is the game's and is
-- used for other sliders too, so the icon is hidden when the row is released.
local function AddExample(initializer)
	local baseInit = initializer.InitFrame
	if type(baseInit) ~= "function" then return end
	initializer.InitFrame = function(self, frame)
		baseInit(self, frame)
		local slider = frame.SliderWithSteppers
		local text = slider and slider.RightText
		if not text then return end
		local icon = frame.ctxExample
		if not icon then
			icon = frame:CreateTexture(nil, "OVERLAY")
			icon:SetSize(EXAMPLE_SIZE, EXAMPLE_SIZE)
			frame.ctxExample = icon
			if frame.Release then
				hooksecurefunc(frame, "Release", function()
					icon:Hide()
					if exampleIcon == icon then exampleIcon = nil end
				end)
			end
		end
		icon:ClearAllPoints()
		icon:SetPoint("LEFT", text, "LEFT", EXAMPLE_X, 0)
		icon:Show()
		exampleIcon = icon
		UpdateExample()
	end
end

local function BuildRoot()
	local layout
	category, layout = Settings.RegisterVerticalLayoutCategory(TITLE)

	-- At the top: on or off, and where everything else is set up (areas, and from their dialogs the event types and
	-- triggers), as Blizzard's own Cooldown Manager page opens Edit Mode.
	local enabled = Settings.CreateCheckbox(category,
		ProfileSetting(category, "enabled", Settings.VarType.Boolean, L.OPT_ENABLED))
	Button(layout, "", L.OPT_OPEN_EDIT_MODE, OpenEditMode, L.OPT_OPEN_EDIT_MODE_TIP)

	-- Style (design document 4.2): how the text looks everywhere.
	Header(layout, L.OPT_HEADER_STYLE)
	local function FontToControl(value) return type(value) == "string" and value or "" end
	local function FontFromControl(value) return value ~= "" and value or false end
	Dropdown(category,
		ProfileSetting(category, "font", Settings.VarType.String, L.OPT_FONT, FontToControl, FontFromControl),
		Choices(FontChoices), L.OPT_FONT_TIP)
	Dropdown(category, ProfileSetting(category, "outline", Settings.VarType.String, L.OPT_OUTLINE),
		Choices(OutlineChoices), L.OPT_OUTLINE_TIP)
	Settings.CreateCheckbox(category, ProfileSetting(category, "shadow", Settings.VarType.Boolean, L.OPT_SHADOW),
		L.OPT_SHADOW_TIP)
	Dropdown(category, ProfileSetting(category, "numbers", Settings.VarType.String, L.OPT_NUMBERS),
		Choices(NumberChoices), L.OPT_NUMBERS_TIP)
	Settings.CreateCheckbox(category,
		ProfileSetting(category, "noBrackets", Settings.VarType.Boolean, L.OPT_NO_BRACKETS), L.OPT_NO_BRACKETS_TIP)
	Settings.CreateCheckbox(category,
		ProfileSetting(category, "alignIcons", Settings.VarType.Boolean, L.OPT_ALIGN_ICONS), L.OPT_ALIGN_ICONS_TIP)
	local zoomOptions = Settings.CreateSliderOptions(0, 50, 1)
	zoomOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, ZoomLabel)
	local zoom = Settings.CreateSlider(category,
		ProfileSetting(category, "iconZoom", Settings.VarType.Number, L.OPT_ICON_ZOOM), zoomOptions)
	AddExample(zoom)
	Settings.CreateCheckbox(category, ProfileSetting(category, "sounds", Settings.VarType.Boolean, L.OPT_SOUNDS),
		L.OPT_SOUNDS_TIP)

	-- Blizzard Settings: the game's own rows, as its Combat options build them (CombatOverrides.lua
	-- CreateFloatingCombatTextSetting), read and set as the game's (4.3): Scrolling Combat Text for Self, then its
	-- Text on Me and Text on Target dropdowns under it. Its float mode isn't here: CTX's areas set where text goes.
	Header(layout, L.OPT_HEADER_BLIZZARD)
	local fctLabel = GlobalText("SHOW_COMBAT_TEXT_TEXT", L.OPT_GAME_FCT)
	local fct = GameCheckbox(GAME_FCT, fctLabel,
		GameSettingTooltip("OPTION_TOOLTIP_SHOW_COMBAT_TEXT"))
	local function GameTextOn() return C_CVar.GetCVarBool(GAME_FCT) == true end
	TextOnMe(fct, GameTextOn)
	TextOnTarget(fct, GameTextOn)

	-- Cooldowns (design document 4.4).
	Header(layout, L.OPT_HEADER_COOLDOWNS)
	Dropdown(category, CooldownSetting("source", Settings.VarType.String, L.OPT_COOLDOWN_SOURCE),
		Choices(CooldownChoices), L.OPT_COOLDOWN_SOURCE_TIP)
	local sliderOptions = Settings.CreateSliderOptions(0, 60, 1)
	sliderOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
		return L.OPT_SECONDS:format(value)
	end)
	local minimum = Settings.CreateSlider(category,
		CooldownSetting("minLength", Settings.VarType.Number, L.OPT_COOLDOWN_MIN), sliderOptions, L.OPT_COOLDOWN_MIN_TIP)
	minimum:AddModifyPredicate(MinimumApplies)
	minimum:AddEvaluateStateCVar("cooldownViewerEnabled")
end

-- Profiles ------------------------------------------------------------------------------------------------------------
-- AceDB profiles, as Better Personal Resource Display and Cooldown Manager Centered offer them (settings.md 2).

local function Trim(text)
	return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function ProfileNames(skipCurrent)
	local names = {}
	if not ns.db then return names end
	local current = ns.db:GetCurrentProfile()
	for _, name in ipairs((ns.db:GetProfiles({}))) do
		if not (skipCurrent and name == current) then names[#names + 1] = name end
	end
	table.sort(names)
	return names
end

local function ProfileExists(name)
	for _, existing in ipairs(ProfileNames()) do
		if existing == name then return true end
	end
	return false
end

local function ProfileChoices(skipCurrent, extra)
	return function()
		local list = {}
		local seen = {}
		for _, name in ipairs(ProfileNames(skipCurrent)) do
			list[#list + 1] = { value = name, text = name }
			seen[name] = true
		end
		if extra and not seen[extra] then
			table.insert(list, 1, { value = extra, text = extra })
		end
		return list
	end
end

local function HasOtherProfiles()
	return #ProfileNames(true) > 0
end

-- A dropdown that picks a profile to act on (copy from, delete): it always reads as a prompt, and picking one asks to
-- confirm.
local function PickerDropdown(where, variable, name, tooltip, popup)
	local setting = Register(where, variable, Settings.VarType.String, name, Settings.CannotDefault,
		function() return "" end,
		function(value)
			if value == "" or RefuseInCombat() then return end
			StaticPopup_Show(popup, value, ns.db and ns.db:GetCurrentProfile() or "", value)
		end)
	local initializer = Dropdown(where, setting, Choices(ProfileChoices(true)), tooltip)
	SelectionText(initializer, function() return L.PROFILE_CHOOSE end)
	initializer:AddModifyPredicate(HasOtherProfiles)
	return initializer
end

-- Export and import (design document 4.2): the profile as CBOR, deflated and in URL-safe base64, behind a version
-- prefix. The game's own encoding, so no extra libraries; every step can fail on bad input, so each is guarded.

-- A plain copy of the profile: AceDB's tables carry metatables for their defaults, which CBOR doesn't need.
local function PlainCopy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, inner in pairs(value) do
		local keyType, innerType = type(key), type(inner)
		if (keyType == "string" or keyType == "number") and innerType ~= "function" and innerType ~= "userdata" then
			copy[key] = PlainCopy(inner)
		end
	end
	return copy
end

local function Step(fn)
	local ok, result = pcall(fn)
	if ok then return result end
	return nil
end

local function Encode(profile)
	local cbor = Step(function() return C_EncodingUtil.SerializeCBOR(PlainCopy(profile)) end)
	if type(cbor) ~= "string" then return nil end
	local packed = Step(function()
		return C_EncodingUtil.CompressString(cbor, Enum.CompressionMethod.Deflate, Enum.CompressionLevel.OptimizeForSize)
	end)
	if type(packed) ~= "string" then return nil end
	local text = Step(function() return C_EncodingUtil.EncodeBase64(packed, Enum.Base64Variant.StandardUrlSafe) end)
	if type(text) ~= "string" then return nil end
	return EXPORT_PREFIX .. text
end

-- Only the profile's own fields, each of the type its default has (false defaults also take text or a table: a font
-- name, a colour). Areas have no defaults (players add them), so any table is taken.
local function Validate(data)
	if type(data) ~= "table" then return nil end
	local defaults = ns.PROFILE_DEFAULTS or {}
	local clean, any = {}, false
	for key, default in pairs(defaults) do
		local value = data[key]
		if value ~= nil then
			local valueType = type(value)
			if valueType ~= type(default) and not (default == false and (valueType == "string" or valueType == "table")) then
				return nil
			end
			clean[key] = value
			any = true
		end
	end
	if data.areas ~= nil then
		if type(data.areas) ~= "table" then return nil end
		clean.areas = data.areas
		any = true
	end
	return any and clean or nil
end

local function Decode(text)
	text = Trim(text)
	if text:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then return nil end
	local body = text:sub(#EXPORT_PREFIX + 1)
	local packed = Step(function() return C_EncodingUtil.DecodeBase64(body, Enum.Base64Variant.StandardUrlSafe) end)
	if type(packed) ~= "string" or packed == "" then return nil end
	local cbor = Step(function() return C_EncodingUtil.DecompressString(packed, Enum.CompressionMethod.Deflate) end)
	if type(cbor) ~= "string" or cbor == "" then return nil end
	return Validate(Step(function() return C_EncodingUtil.DeserializeCBOR(cbor) end))
end

-- Fills a table that may carry AceDB's defaults without replacing it, so the defaults stay in place.
local function Merge(into, from)
	for key, value in pairs(from) do
		if type(value) == "table" and type(into[key]) == "table" then
			Merge(into[key], value)
		else
			into[key] = value
		end
	end
end

-- A new profile from imported data. Areas and the player's own triggers are lists the player builds, so they're
-- taken as they are rather than merged into the new profile's preset areas.
local function CreateImported(name, data)
	ns.db:SetProfile(name)
	local profile = ns.db.profile
	local areas = data.areas
	data.areas = nil
	local custom = type(data.triggers) == "table" and data.triggers.custom or nil
	if type(data.triggers) == "table" then data.triggers.custom = nil end
	Merge(profile, data)
	if type(areas) == "table" and next(areas) ~= nil then profile.areas = areas end
	if type(profile.triggers) == "table" then profile.triggers.custom = type(custom) == "table" and custom or nil end
	ns.ProfileChanged()
end

local function NewProfile(name)
	ns.db:SetProfile(name)
end

-- Checks a name typed for a new profile. Returns it, or nil after saying why not.
local function NewName(editBox)
	local name = Trim(editBox:GetText())
	if name == "" then return nil end
	if ProfileExists(name) then
		ns.Print(L.PROFILE_EXISTS:format(name))
		return nil
	end
	return name
end

local function ExportProfile()
	if RefuseInCombat() or not ns.db then return end
	local text = Encode(ns.profile)
	if not text then
		ns.Print(L.PROFILE_EXPORT_FAILED)
		return
	end
	StaticPopup_Show(POPUP_PREFIX .. "PROFILE_EXPORT", ns.db:GetCurrentProfile(), nil, { text = text })
end

local function BuildProfiles()
	local layout
	profilesCategory, layout = Settings.RegisterVerticalLayoutSubcategory(category, L.PROFILE_PAGE)

	local active = Register(profilesCategory, "PROFILE_ACTIVE", Settings.VarType.String, L.PROFILE_ACTIVE,
		Settings.CannotDefault,
		function() return ns.db and ns.db:GetCurrentProfile() or "" end,
		function(value)
			if not ns.db or RefuseInCombat() then
				RefreshSoon()
				return
			end
			ns.db:SetProfile(value)
		end)
	Dropdown(profilesCategory, active, Choices(ProfileChoices(false)))

	-- The default for new characters may name a profile that doesn't exist yet (AceDB makes it on first use).
	local defaultSetting = Register(profilesCategory, "PROFILE_DEFAULT", Settings.VarType.String, L.PROFILE_DEFAULT,
		Settings.CannotDefault,
		function() return ns.global and ns.global.defaultProfile or "Default" end,
		function(value)
			if not ns.global or RefuseInCombat() then
				RefreshSoon()
				return
			end
			ns.global.defaultProfile = value
		end)
	Dropdown(profilesCategory, defaultSetting, Choices(function()
		return ProfileChoices(false, ns.global and ns.global.defaultProfile or "Default")()
	end))

	Button(layout, "", L.PROFILE_NEW, function()
		if RefuseInCombat() then return end
		StaticPopup_Show(POPUP_PREFIX .. "PROFILE_NEW")
	end)
	PickerDropdown(profilesCategory, "PROFILE_COPY", L.PROFILE_COPY, nil, POPUP_PREFIX .. "PROFILE_COPY")
	PickerDropdown(profilesCategory, "PROFILE_DELETE", L.PROFILE_DELETE, nil,
		POPUP_PREFIX .. "PROFILE_DELETE")
	Button(layout, "", L.PROFILE_RESET, function()
		if RefuseInCombat() or not ns.db then return end
		StaticPopup_Show(POPUP_PREFIX .. "PROFILE_RESET", ns.db:GetCurrentProfile())
	end)
	Button(layout, "", L.PROFILE_EXPORT, ExportProfile)
	Button(layout, "", L.PROFILE_IMPORT, function()
		if RefuseInCombat() then return end
		StaticPopup_Show(POPUP_PREFIX .. "PROFILE_IMPORT")
	end)

	-- Presets (design document 1.1, 4.1): each sets up the profile in use (areas, event types, style), after asking.
	Header(layout, L.OPT_HEADER_PRESETS, L.OPT_HEADER_PRESETS_TIP)
	for _, preset in ipairs(ns.PRESETS or {}) do
		Button(layout, preset.label, L.OPT_PRESET_USE, function() PresetPopup(preset) end, preset.description)
	end
end

-- Popups --------------------------------------------------------------------------------------------------------------

local function Popup(key, info)
	local name = POPUP_PREFIX .. key
	info.timeout = 0
	info.whileDead = true
	info.hideOnEscape = true
	StaticPopupDialogs[name] = info
	popups[#popups + 1] = name
end

-- Enter clicks the first button, as in the game's own popups with a text box.
local function EnterClicksAccept(editBox)
	local button = editBox:GetParent():GetButton1()
	if button:IsEnabled() then button:Click() end
end

-- The first button only works once something is typed.
local function NeedsText(editBox)
	StaticPopup_StandardNonEmptyTextHandler(editBox)
end

local function DisableAccept(dialog)
	dialog:GetButton1():Disable()
end

-- The game's switches that keep a preset's text from showing: those of every type the preset sets up and leaves on,
-- where the game has all of the type's switches off.
local function SwitchesOff(preset)
	local cvars, seen = {}, {}
	for key in pairs(preset.types or {}) do
		local def = ns.TYPE and ns.TYPE[key]
		local settings = ns.Router and ns.Router.TypeSettings and ns.Router.TypeSettings(key)
		local list = def and (def.gameSettings or (def.gameSetting and { def.gameSetting }))
		if list and settings and settings.enabled ~= false then
			local anyOn = false
			for _, cvar in ipairs(list) do
				if ns.GameSetting(cvar) then anyOn = true end
			end
			for _, cvar in ipairs(anyOn and {} or list) do
				if not seen[cvar] then
					seen[cvar] = true
					cvars[#cvars + 1] = cvar
				end
			end
		end
	end
	table.sort(cvars)
	return cvars
end

-- After a preset with gameSwitches is applied, asks once to turn on the game's switches its text needs. Asking keeps
-- the game's settings the player's own: nothing changes unless they click Turn On.
local function OfferSwitches(key)
	local preset = ns.PRESET and ns.PRESET[key]
	if not (preset and preset.gameSwitches) then return end
	local cvars = SwitchesOff(preset)
	if #cvars == 0 then return end
	local labels = {}
	for i, cvar in ipairs(cvars) do
		labels[i] = ns.GameSettingLabel(cvar) or cvar
	end
	StaticPopup_Show(POPUP_PREFIX .. "SWITCHES", table.concat(labels, "\n"), nil, cvars)
end

Popup("PRESET", {
	text = L.OPT_PRESET_CONFIRM, -- %s the preset's name
	button1 = YES, button2 = NO, showAlert = true,
	OnAccept = function(_, key)
		if RefuseInCombat() or not ns.ApplyPreset then return end
		ns.ApplyPreset(key)
		C_Timer.After(0, function() OfferSwitches(key) end)
	end,
})

Popup("SWITCHES", {
	text = L.OPT_PRESET_SWITCHES, -- %s the switches, one per line, in the game's words
	button1 = L.OPT_PRESET_SWITCHES_ON, button2 = L.OPT_PRESET_SWITCHES_NOT_NOW,
	OnAccept = function(_, cvars)
		if RefuseInCombat() then return end
		for _, cvar in ipairs(cvars or {}) do
			SetGameSetting(cvar, ns.GameSettingLabel(cvar) or cvar, true)
		end
	end,
})

Popup("PROFILE_NEW", {
	text = L.PROFILE_NEW_TEXT,
	button1 = ACCEPT, button2 = CANCEL,
	hasEditBox = true, maxLetters = NAME_LETTERS,
	OnShow = DisableAccept,
	EditBoxOnTextChanged = NeedsText,
	EditBoxOnEnterPressed = EnterClicksAccept,
	OnAccept = function(dialog)
		if RefuseInCombat() or not ns.db then return end
		local name = NewName(dialog:GetEditBox())
		if not name then return true end
		NewProfile(name)
	end,
})

Popup("PROFILE_COPY", {
	text = L.PROFILE_COPY_CONFIRM, -- %s the profile copied from, %s the current one
	button1 = YES, button2 = NO, showAlert = true,
	OnAccept = function(_, source)
		if RefuseInCombat() or not ns.db or not ProfileExists(source) then return end
		if source == ns.db:GetCurrentProfile() then return end
		ns.db:CopyProfile(source)
	end,
})

Popup("PROFILE_DELETE", {
	text = L.PROFILE_DELETE_CONFIRM, -- %s the profile
	button1 = YES, button2 = NO, showAlert = true,
	OnAccept = function(_, name)
		if RefuseInCombat() or not ns.db or not ProfileExists(name) then return end
		if name == ns.db:GetCurrentProfile() then return end
		ns.db:DeleteProfile(name)
		-- New characters would otherwise get a fresh profile of that name back.
		if ns.global and ns.global.defaultProfile == name then
			ns.global.defaultProfile = "Default"
		end
		RefreshSoon()
	end,
})

Popup("PROFILE_RESET", {
	text = L.PROFILE_RESET_CONFIRM, -- %s the profile
	button1 = YES, button2 = NO, showAlert = true,
	OnAccept = function()
		if RefuseInCombat() or not ns.db then return end
		ns.db:ResetProfile()
	end,
})

-- The text is selected for copying, and typing can't change it.
Popup("PROFILE_EXPORT", {
	text = L.PROFILE_EXPORT_TEXT, -- %s the profile
	button1 = CLOSE,
	hasEditBox = true, editBoxWidth = 350, maxLetters = 0,
	OnShow = function(dialog, data)
		local editBox = dialog:GetEditBox()
		editBox:SetText(data.text)
		editBox:HighlightText()
		editBox:SetFocus()
	end,
	EditBoxOnTextChanged = function(editBox, data)
		-- Not while hiding, when the game empties the box for the next popup.
		if editBox:GetParent():IsShown() and data and editBox:GetText() ~= data.text then
			editBox:SetText(data.text)
			editBox:HighlightText()
		end
	end,
	EditBoxOnEnterPressed = function(editBox) editBox:GetParent():Hide() end,
})

-- Importing is two steps, as in both model addons: paste the text (checked before going on), then name the profile.
Popup("PROFILE_IMPORT", {
	text = L.PROFILE_IMPORT_TEXT,
	button1 = NEXT, button2 = CANCEL,
	hasEditBox = true, editBoxWidth = 350, maxLetters = 0,
	OnShow = DisableAccept,
	EditBoxOnTextChanged = NeedsText,
	EditBoxOnEnterPressed = EnterClicksAccept,
	OnAccept = function(dialog)
		if RefuseInCombat() then return end
		local data = Decode(dialog:GetEditBox():GetText())
		if not data then
			ns.Print(L.PROFILE_IMPORT_BAD)
			return true
		end
		StaticPopup_Show(POPUP_PREFIX .. "PROFILE_IMPORT_NAME", nil, nil, data)
	end,
})

Popup("PROFILE_IMPORT_NAME", {
	text = L.PROFILE_IMPORT_NAME_TEXT,
	button1 = ACCEPT, button2 = CANCEL,
	hasEditBox = true, maxLetters = NAME_LETTERS,
	OnShow = DisableAccept,
	EditBoxOnTextChanged = NeedsText,
	EditBoxOnEnterPressed = EnterClicksAccept,
	OnAccept = function(dialog, data)
		if RefuseInCombat() or not ns.db then return end
		local name = NewName(dialog:GetEditBox())
		if not name then return true end
		CreateImported(name, data)
	end,
})

-- Opening -------------------------------------------------------------------------------------------------------------

function Options.Open(subpage)
	if not category or RefuseInCombat() then return false end
	local target = subpage == "profiles" and profilesCategory or category
	Settings.OpenToCategory(target:GetID())
	return true
end

-- Building and keeping current -------------------------------------------------------------------------------------

-- The game's rows show their name as a tooltip even when there's nothing more to say. On CTX's pages a tooltip that's
-- only that title is hidden (one hook on the game's settings tooltip, which does nothing on its other pages).
local function OnOwnPage()
	local current = SettingsPanel and SettingsPanel.GetCurrentCategory and SettingsPanel:GetCurrentCategory()
	return current ~= nil and (current == category or current == profilesCategory)
end

local function HideBareTooltips()
	if not (SettingsTooltip and SettingsTooltip.NumLines) then return end
	hooksecurefunc(SettingsTooltip, "Show", function(tooltip)
		local lines = tooltip:NumLines()
		if type(lines) == "number" and lines <= 1 and OnOwnPage() then tooltip:Hide() end
	end)
end

ns.Listen("DB_READY", function()
	if category then return end
	BuildRoot()
	BuildProfiles()
	Settings.RegisterAddOnCategory(category)
	HideBareTooltips()
end)

-- A profile change (nil) changes everything; CTX's own changes from this page are already shown.
ns.Listen("SETTINGS_CHANGED", function(what)
	if what == nil then RefreshSoon() end
	if what == nil or what == "iconZoom" then UpdateExample() end
end)

ns.Listen("GAME_SETTING_CHANGED", RefreshSoon)

-- Nothing of CTX's stays open in combat (design document 4.2). The game's options page itself is the game's, so it's
-- left open; its CTX controls refuse changes until combat ends.
ns.Listen("COMBAT", function(inCombat)
	if not inCombat then return end
	for _, name in ipairs(popups) do
		StaticPopup_Hide(name)
	end
end)
