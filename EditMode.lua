local addonName, ns = ...
local L = ns.L

-- Each area's holder is an Edit Mode frame through LibEditMode (design document 4.2): selected, moved and set up in
-- the game's Edit Mode like its own frames, with a dialog per area. LibEditMode saves nothing, so positions are kept
-- here, per Edit Mode layout. Neither this file nor LibEditMode touches Blizzard's registeredSystemFrames or layouts.

local LEM = ns.LEM
local EditMode = {}
ns.EditMode = EditMode

-- Areas show sample text this often while Edit Mode is open, so empty areas can be placed.
local SAMPLE_EVERY = 1.2
local NAME_LETTERS = 32
local RENAME_POPUP = "COMBATTEXTEXTENDED_RENAME_AREA"
local DELETE_POPUP = "COMBATTEXTEXTENDED_DELETE_AREA"

-- Blizzard's own defaults for an area (Architecture.md's AreaSettings), used when the default area has none.
local FALLBACK = {
	style = "blizzard", direction = "up", behavior = false, stickyStyle = "blizzard", stickyBehavior = false,
	align = "center", duration = 1.9, fontSize = 25, width = 300, height = 250, icons = "left", stagger = true,
	overflow = "shift",
}
local DEFAULT_POSITION = { point = "BOTTOM", x = 0, y = 295 } -- Blizzard's own place for its text (Presets.lua)

-- Blizzard's Copy Layout passes a preset by its translated name; LibEditMode always names presets in English.
local PRESET_NAMES = {}
for global, name in pairs({ LAYOUT_STYLE_MODERN = "Modern", LAYOUT_STYLE_CLASSIC = "Classic", LAYOUT_STYLE_GAMEPAD = "Gamepad" }) do
	if type(_G[global]) == "string" then PRESET_NAMES[_G[global]] = name end
end

-- Choices the styles offer, by value. Blizzard's own Edit Mode words where it has them, so they match its dialogs.
local CHOICE_TEXT = {
	up = HUD_EDIT_MODE_SETTING_BAGS_DIRECTION_UP,
	down = HUD_EDIT_MODE_SETTING_BAGS_DIRECTION_DOWN,
	left = HUD_EDIT_MODE_SETTING_BAGS_DIRECTION_LEFT,
	right = HUD_EDIT_MODE_SETTING_BAGS_DIRECTION_RIGHT,
	center = L.EDITMODE_CHOICE_CENTRE,
	alternate = L.EDITMODE_CHOICE_ALTERNATE,
	normal = L.EDITMODE_CHOICE_NORMAL,
	jiggle = L.EDITMODE_CHOICE_JIGGLE,
	off = L.EDITMODE_CHOICE_OFF,
	shift = L.EDITMODE_CHOICE_SHIFT,
	push = L.EDITMODE_CHOICE_PUSH,
	stack = L.EDITMODE_CHOICE_STACK,
}

-- holder -> the default position table LibEditMode was given for it (LibEditMode keeps the table, so it's updated in
-- place when the holder's area changes).
local registered = {}
local dialogFrame
local ticker

-- Messages ------------------------------------------------------------------------------------------------------------

-- As Blizzard's /editmode reports that it can't open: a system line in the main chat frame.
local function SystemMessage(text)
	if ChatFrameUtil and ChatFrameUtil.DisplaySystemMessageInPrimary then
		ChatFrameUtil.DisplaySystemMessageInPrimary(text)
	else
		ns.Print(text)
	end
end

-- Refusals while in Edit Mode go where the game puts its own: the red error text at the top of the screen.
local function Refuse(text)
	if UIErrorsFrame and UIErrorsFrame.AddExternalErrorMessage then
		UIErrorsFrame:AddExternalErrorMessage(text)
	else
		ns.Print(text)
	end
end

local function RefuseInCombat()
	if not ns.InCombat() then return false end
	Refuse(ERR_NOT_IN_COMBAT or L.EDITMODE_IN_COMBAT)
	return true
end

-- Areas and styles ----------------------------------------------------------------------------------------------------

-- Areas may reuse a holder for another area, so a holder's area is looked up each time, never kept.
local function AreaOf(holder)
	local list = ns.Areas and ns.Areas.list
	if not list then return nil end
	for id, area in pairs(list) do
		if area.holder == holder then return area, id end
	end
end

local function SettingsOf(holder)
	local _, id = AreaOf(holder)
	if id == nil or not (ns.Areas and ns.Areas.Settings) then return nil end
	return ns.Areas.Settings(id), id
end

local function AreaIDs()
	return ns.Areas and ns.Areas.Order and ns.Areas.Order() or {}
end

-- The default area's value for an area setting: what Reset To Default goes back to.
local function BlizzardDefault(field)
	local area = ns.DEFAULT_AREAS and ns.DEFAULT_AREAS.main
	if type(area) == "table" and area[field] ~= nil then return area[field] end
	return FALLBACK[field]
end

local function Style(kind, key)
	local styles = ns.Styles and ns.Styles[kind]
	return styles and key ~= nil and styles[key] or nil
end

-- The styles of one kind ("normal" or "sticky") in Styles.lua's order.
local function StyleList(kind)
	local styles = ns.Styles
	local order = styles and styles[kind .. "Order"]
	local list = {}
	if not order then return list end
	for _, entry in ipairs(order) do
		if type(entry) ~= "table" then entry = Style(kind, entry) end
		if entry then list[#list + 1] = entry end
	end
	return list
end

-- A style's directions and behaviours are values; a table entry with its own text is taken as it is.
local function ChoiceValue(entry)
	if type(entry) == "table" then return entry.value or entry.key end
	return entry
end

local function ChoiceText(entry)
	if type(entry) == "table" and (entry.text or entry.label) then return entry.text or entry.label end
	local value = ChoiceValue(entry)
	return CHOICE_TEXT[value] or tostring(value)
end

local function Choices(list)
	local values = {}
	for _, entry in ipairs(list or {}) do
		values[#values + 1] = { text = ChoiceText(entry), value = ChoiceValue(entry) }
	end
	return values
end

local function Has(list, value)
	for _, entry in ipairs(list or {}) do
		if ChoiceValue(entry) == value then return true end
	end
	return false
end

local function First(list)
	if not list or list[1] == nil then return false end
	return ChoiceValue(list[1])
end

-- The value a style's choice really has: a stored one the style doesn't offer (or false) means its first.
local function Effective(list, value)
	if not list or list[1] == nil then return false end
	if Has(list, value) then return value end
	return First(list)
end

-- After a style change, keep direction and behaviour to ones the new style offers.
local function FixChoices(settings)
	local normal = Style("normal", settings.style)
	if normal then
		settings.direction = Effective(normal.directions, settings.direction)
		settings.behavior = Effective(normal.behaviors, settings.behavior)
	end
	local sticky = Style("sticky", settings.stickyStyle)
	if sticky then
		settings.stickyBehavior = Effective(sticky.behaviors, settings.stickyBehavior)
	end
end

-- Positions per layout --------------------------------------------------------------------------------------------------

function EditMode.IsActive()
	return LEM:IsInEditMode()
end

-- nil until the game has sent its layouts.
function EditMode.LayoutName()
	return LEM:GetActiveLayoutName()
end

-- The area's position in a layout, created from its default the first time the layout is seen (design document 4.2).
local function PositionFor(settings, layoutName)
	local default = type(settings.default) == "table" and settings.default or DEFAULT_POSITION
	if not layoutName then return default end
	if type(settings.positions) ~= "table" then settings.positions = {} end
	local position = settings.positions[layoutName]
	if type(position) ~= "table" or not position.point then
		position = { point = default.point, x = default.x, y = default.y }
		settings.positions[layoutName] = position
	end
	return position
end

-- The dialog title and the selection box's label read holder.editModeName. The label only reads it when the box is
-- shown or selected, so a selected box is told again.
local function ShowName(holder, name)
	if holder.editModeName == name then return end
	holder.editModeName = name
	local selection = LEM.frameSelections and LEM.frameSelections[holder]
	if selection and selection:IsShown() and selection.UpdateLabelVisibility then selection:UpdateLabelVisibility() end
end

-- One SetPoint, on the same point of UIParent, as LibEditMode's Reset Position compares the first point with the default.
local function Place(id, area, layoutName)
	local holder = area and area.holder
	local settings = holder and ns.Areas.Settings(id)
	if not settings then return end
	ShowName(holder, settings.name)
	local proxy = registered[holder]
	if proxy then
		local default = type(settings.default) == "table" and settings.default or DEFAULT_POSITION
		proxy.point, proxy.x, proxy.y = default.point, default.x, default.y
	end
	local position = PositionFor(settings, layoutName or EditMode.LayoutName())
	holder:ClearAllPoints()
	holder:SetPoint(position.point, UIParent, position.point, position.x or 0, position.y or 0)
	if ns.Areas.Relayout then ns.Areas.Relayout(id) end
end

local function PlaceAll(layoutName)
	if not (ns.Areas and ns.Areas.list and ns.Areas.Settings) then return end
	for id, area in pairs(ns.Areas.list) do
		Place(id, area, layoutName)
	end
end

-- LibEditMode calls this when a drag ends, on an arrow key nudge and on Reset Position.
local function OnMoved(holder, layoutName, point, x, y)
	local settings, id = SettingsOf(holder)
	layoutName = layoutName or EditMode.LayoutName()
	if not settings or not layoutName then return end
	if type(settings.positions) ~= "table" then settings.positions = {} end
	settings.positions[layoutName] = { point = point, x = x, y = y }
	if ns.Areas.Relayout then ns.Areas.Relayout(id) end
end

-- Layouts belong to the account or character, not the profile. A renamed or deleted account layout changes every
-- profile; a character's own layout only the profile that character uses, as other characters sharing the profile
-- may have their own layout of the same name.
local function ForEachPositions(fn, currentOnly)
	local profiles = ns.db and ns.db.profiles
	if type(profiles) ~= "table" then return end
	if currentOnly then profiles = { ns.profile } end
	for _, profile in pairs(profiles) do
		if type(profile) == "table" and type(profile.areas) == "table" then
			for _, area in pairs(profile.areas) do
				if type(area) == "table" and type(area.positions) == "table" then fn(area.positions) end
			end
		end
	end
end

local function OnLayout(layoutName)
	if not ns.profile then return end
	PlaceAll(layoutName)
	ns.Fire("LAYOUT", layoutName)
end

-- Whether a layout is a character's own. LibEditMode calls back before it updates its list, so the list still has the
-- deleted or renamed layout (index: its place there, when known).
local function IsCharacterLayout(name, index)
	local cache = LEM.layoutCache
	local character = Enum.EditModeLayoutType and Enum.EditModeLayoutType.Character
	if type(cache) ~= "table" or character == nil then return false end
	local entry = index and cache[index]
	if not (type(entry) == "table" and entry.layoutName == name) then
		entry = nil
		for _, layout in ipairs(cache) do
			if type(layout) == "table" and layout.layoutName == name then
				entry = layout
				break
			end
		end
	end
	return entry ~= nil and entry.layoutType == character
end

local function OnRename(oldName, newName, index)
	if oldName == nil or newName == nil or oldName == newName then return end
	ForEachPositions(function(positions)
		if positions[oldName] ~= nil then
			positions[newName] = positions[oldName]
			positions[oldName] = nil
		end
	end, IsCharacterLayout(oldName, index))
end

local function OnDelete(layoutName)
	if layoutName == nil then return end
	ForEachPositions(function(positions) positions[layoutName] = nil end, IsCharacterLayout(layoutName))
end

-- LibEditMode can report the wrong new layout (a new account layout goes before character ones), so an existing entry
-- is never overwritten; any layout still without one gets it from the default when it's first used. With no source,
-- Blizzard's New Layout copies the active layout, which LibEditMode still reports here (it switches afterwards).
local function OnCreate(layoutName, _, sourceName)
	sourceName = sourceName or EditMode.LayoutName()
	if layoutName == nil or sourceName == nil then return end
	sourceName = PRESET_NAMES[sourceName] or sourceName
	if sourceName == layoutName then return end
	ForEachPositions(function(positions)
		local source = positions[sourceName]
		if positions[layoutName] == nil and type(source) == "table" then
			positions[layoutName] = { point = source.point, x = source.x, y = source.y }
		end
	end)
end

-- Dialogs -------------------------------------------------------------------------------------------------------------

-- LibEditMode's own way of closing every LibEditMode dialog (its frames and other addons' copies all listen to it).
local function HideDialog()
	if LEM:IsInEditMode() then
		EventRegistry:TriggerEvent("EditModeExternal.hideDialog")
	end
end

local function ClosePopups()
	StaticPopup_Hide(RENAME_POPUP)
	StaticPopup_Hide(DELETE_POPUP)
	if ns.EventTypes and ns.EventTypes.Close then ns.EventTypes.Close() end
end

-- The settings dialog the area buttons sit in, for placing the Event Types popup beside it (nil until one is clicked).
function EditMode.Dialog()
	return dialogFrame
end

local function Remember()
	local dialog = LEM.internal and LEM.internal.dialog
	if dialog then dialogFrame = dialog end
end

-- Rebuilds the open dialog (a dropdown's text only updates when the dialog is built). Next frame, so it never happens
-- inside the dialog's own click handling.
local function RefreshDialog(holder)
	C_Timer.After(0, function() LEM:RefreshFrameSettings(holder) end)
end

-- Reset To Default sets every setting in a row; tell the area once.
local pendingChanges = {}
local function Changed(id, fromReset)
	if not fromReset then
		ns.Areas.Changed(id)
		return
	end
	if pendingChanges[id] then return end
	pendingChanges[id] = true
	C_Timer.After(0, function()
		pendingChanges[id] = nil
		if ns.Areas.Settings(id) then ns.Areas.Changed(id) end
	end)
end

local function Round(value)
	return math.floor(value + 0.5)
end

local function RoundTenth(value)
	return math.floor(value * 10 + 0.5) / 10
end

-- Getters ignore the layout name (area settings aren't per layout) and cope with an area that's gone.
local function Getter(holder, field, effective)
	return function()
		local settings = SettingsOf(holder)
		if not settings then return BlizzardDefault(field) end
		if effective then return effective(settings) end
		return settings[field]
	end
end

local function Setter(holder, field, round, after)
	return function(_, value, fromReset)
		local settings, id = SettingsOf(holder)
		if not settings then return end
		if round and type(value) == "number" then value = round(value) end
		if settings[field] == value then return end
		settings[field] = value
		if after then after(settings, fromReset) end
		Changed(id, fromReset)
	end
end

-- The dialog doesn't scroll, so it holds only the per-area settings of design document 4.1; behaviours only show for
-- styles that have them.
local function BuildSettings(holder)
	local Dropdown, Slider, Checkbox = LEM.SettingType.Dropdown, LEM.SettingType.Slider, LEM.SettingType.Checkbox

	local function CurrentStyle(kind, field)
		local settings = SettingsOf(holder)
		return Style(kind, settings and settings[field])
	end

	local function StyleValues(kind)
		return function()
			local values = {}
			for _, style in ipairs(StyleList(kind)) do
				values[#values + 1] = { text = style.label or tostring(style.key), value = style.key }
			end
			return values
		end
	end

	local function StyleChanged(settings, fromReset)
		FixChoices(settings)
		if not fromReset then RefreshDialog(holder) end
	end

	-- Five lines showing the change: sticky ones for the sticky style and effect, ones with icons for Icons.
	local function Burst(kind, also)
		return function(settings, fromReset)
			if also then also(settings, fromReset) end
			if fromReset then return end
			local _, id = SettingsOf(holder)
			if id ~= nil and ns.Router and ns.Router.SampleBurst then ns.Router.SampleBurst(id, kind) end
		end
	end

	local function NoBehaviours(kind, field)
		return function()
			local style = CurrentStyle(kind, field)
			return not (style and style.behaviors and style.behaviors[1] ~= nil)
		end
	end

	return {
		{
			kind = Dropdown, name = L.EDITMODE_STYLE, default = BlizzardDefault("style"),
			values = StyleValues("normal"),
			get = Getter(holder, "style"),
			set = Setter(holder, "style", nil, StyleChanged),
		},
		{
			kind = Dropdown, name = HUD_EDIT_MODE_SETTING_BAGS_DIRECTION, default = BlizzardDefault("direction"),
			values = function()
				local style = CurrentStyle("normal", "style")
				return Choices(style and style.directions)
			end,
			get = Getter(holder, "direction", function(settings)
				local style = Style("normal", settings.style)
				return style and Effective(style.directions, settings.direction) or settings.direction
			end),
			set = Setter(holder, "direction"),
		},
		{
			kind = Dropdown, name = L.EDITMODE_BEHAVIOUR, default = BlizzardDefault("behavior"),
			values = function()
				local style = CurrentStyle("normal", "style")
				return Choices(style and style.behaviors)
			end,
			get = Getter(holder, "behavior", function(settings)
				local style = Style("normal", settings.style)
				return style and Effective(style.behaviors, settings.behavior) or settings.behavior
			end),
			set = Setter(holder, "behavior"),
			hidden = NoBehaviours("normal", "style"),
		},
		{
			-- What Blizzard-style lines do when they come faster than they move away (design document 4.1).
			kind = Dropdown, name = L.EDITMODE_OVERFLOW, desc = L.EDITMODE_OVERFLOW_DESC,
			default = BlizzardDefault("overflow"),
			values = Choices({ "shift", "push", "stack" }),
			get = Getter(holder, "overflow", function(settings) return settings.overflow or "shift" end),
			set = Setter(holder, "overflow"),
			hidden = function()
				local style = CurrentStyle("normal", "style")
				return not (style and style.stacks)
			end,
		},
		{
			kind = Dropdown, name = L.EDITMODE_STICKY_STYLE,
			default = BlizzardDefault("stickyStyle"),
			values = StyleValues("sticky"),
			get = Getter(holder, "stickyStyle"),
			set = Setter(holder, "stickyStyle", nil, Burst("sticky", StyleChanged)),
		},
		{
			kind = Dropdown, name = L.EDITMODE_STICKY_BEHAVIOUR, default = BlizzardDefault("stickyBehavior"),
			values = function()
				local style = CurrentStyle("sticky", "stickyStyle")
				return Choices(style and style.behaviors)
			end,
			get = Getter(holder, "stickyBehavior", function(settings)
				local style = Style("sticky", settings.stickyStyle)
				return style and Effective(style.behaviors, settings.stickyBehavior) or settings.stickyBehavior
			end),
			set = Setter(holder, "stickyBehavior", nil, Burst("sticky")),
			hidden = NoBehaviours("sticky", "stickyStyle"),
		},
		{
			kind = Dropdown, name = L.EDITMODE_ALIGN, default = BlizzardDefault("align"),
			values = Choices({ "left", "center", "right" }),
			get = Getter(holder, "align"),
			set = Setter(holder, "align"),
		},
		{
			-- Blizzard moves damage and misses up to 10 sideways at random; off keeps them in line.
			kind = Checkbox, name = L.EDITMODE_STAGGER, desc = L.EDITMODE_STAGGER_DESC,
			default = BlizzardDefault("stagger") ~= false,
			get = Getter(holder, "stagger", function(settings) return settings.stagger ~= false end),
			set = Setter(holder, "stagger"),
		},
		{
			-- Which side of the text spell and item icons go on (cooldowns, loot, triggers), or none.
			kind = Dropdown, name = L.EDITMODE_ICONS, default = BlizzardDefault("icons"),
			values = Choices({ "left", "right", "off" }),
			get = Getter(holder, "icons"),
			set = Setter(holder, "icons", nil, Burst("icons")),
		},
		{
			kind = Slider, name = L.EDITMODE_DURATION, default = BlizzardDefault("duration"),
			minValue = 0.5, maxValue = 6, valueStep = 0.1,
			formatter = function(value) return L.EDITMODE_SECONDS:format(value) end,
			get = Getter(holder, "duration"),
			set = Setter(holder, "duration", RoundTenth),
		},
		{
			kind = Slider, name = HUD_EDIT_MODE_SETTING_DAMAGE_METER_TEXT_SIZE, default = BlizzardDefault("fontSize"),
			minValue = 10, maxValue = 48, valueStep = 1,
			get = Getter(holder, "fontSize"),
			set = Setter(holder, "fontSize", Round),
		},
		{
			kind = Slider, name = HUD_EDIT_MODE_SETTING_CHAT_FRAME_WIDTH, default = BlizzardDefault("width"),
			minValue = 40, maxValue = 800, valueStep = 1,
			get = Getter(holder, "width"),
			set = Setter(holder, "width", Round),
		},
		{
			kind = Slider, name = HUD_EDIT_MODE_SETTING_CHAT_FRAME_HEIGHT, default = BlizzardDefault("height"),
			minValue = 0, maxValue = 600, valueStep = 1,
			get = Getter(holder, "height"),
			set = Setter(holder, "height", Round),
		},
	}
end

-- Area buttons ----------------------------------------------------------------------------------------------------------

local function NewAreaName()
	local ids = AreaIDs()
	local taken = {}
	for _, id in ipairs(ids) do
		local settings = ns.Areas.Settings(id)
		if settings and settings.name then taken[settings.name] = true end
	end
	local n = #ids + 1
	while taken[L.EDITMODE_NEW_AREA_NAME:format(n)] do n = n + 1 end
	return L.EDITMODE_NEW_AREA_NAME:format(n)
end

-- True once the area has its new name.
local function RenameFrom(editBox, id)
	local name = strtrim(editBox:GetText() or "")
	if name == "" or not ns.Areas.Settings(id) then return false end
	ns.Areas.Rename(id, name)
	local area = ns.Areas.list and ns.Areas.list[id]
	if area and area.holder then
		local settings = ns.Areas.Settings(id)
		ShowName(area.holder, settings and settings.name or name)
		RefreshDialog(area.holder)
	end
	return true
end

local function DeleteArea(id)
	if RefuseInCombat() then return end
	if #AreaIDs() <= 1 then
		Refuse(L.EDITMODE_LAST_AREA)
		return
	end
	if not ns.Areas.Settings(id) then return end
	-- The dialog would stay open on a hidden holder.
	HideDialog()
	ns.Areas.Delete(id)
end

StaticPopupDialogs[RENAME_POPUP] = {
	text = L.EDITMODE_RENAME_PROMPT,
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = true,
	maxLetters = NAME_LETTERS,
	OnShow = function(dialog, id)
		local settings = ns.Areas.Settings(id)
		local editBox = dialog:GetEditBox()
		editBox:SetText(settings and settings.name or "")
		editBox:HighlightText()
		editBox:SetFocus()
	end,
	OnAccept = function(dialog, id)
		RenameFrom(dialog:GetEditBox(), id)
	end,
	EditBoxOnEnterPressed = function(editBox, id)
		if RenameFrom(editBox, id) then editBox:GetParent():Hide() end
	end,
	EditBoxOnTextChanged = StaticPopup_StandardNonEmptyTextHandler,
	EditBoxOnEscapePressed = StaticPopup_StandardEditBoxOnEscapePressed,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

StaticPopupDialogs[DELETE_POPUP] = {
	text = L.EDITMODE_DELETE_PROMPT,
	button1 = DELETE,
	button2 = CANCEL,
	OnAccept = function(_, id) DeleteArea(id) end,
	showAlert = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- Buttons don't say which area they're for, so each holder gets its own, finding its area when clicked. In the
-- dialog's grid: New Area, Rename, then Delete Area, Event Types.
local function BuildButtons(holder)
	return {
		{
			text = L.EDITMODE_NEW,
			click = function()
				Remember()
				if RefuseInCombat() or not (ns.Areas and ns.Areas.New) then return end
				-- Nothing selected afterwards: the new area shows highlighted, ready to be clicked and placed.
				HideDialog()
				ns.Areas.New(NewAreaName())
			end,
		},
		{
			text = L.EDITMODE_RENAME,
			click = function()
				Remember()
				if RefuseInCombat() then return end
				local settings, id = SettingsOf(holder)
				if settings then StaticPopup_Show(RENAME_POPUP, settings.name or "", nil, id) end
			end,
		},
		{
			text = L.EDITMODE_DELETE,
			click = function()
				Remember()
				if RefuseInCombat() then return end
				local settings, id = SettingsOf(holder)
				if not settings then return end
				if #AreaIDs() <= 1 then
					Refuse(L.EDITMODE_LAST_AREA)
					return
				end
				StaticPopup_Show(DELETE_POPUP, settings.name or "", nil, id)
			end,
		},
		{
			text = L.EDITMODE_EVENT_TYPES,
			click = function()
				Remember()
				if RefuseInCombat() then return end
				local _, id = SettingsOf(holder)
				if id ~= nil and ns.EventTypes and ns.EventTypes.Open then ns.EventTypes.Open(id) end
			end,
		},
	}
end

-- The areas' dialog -----------------------------------------------------------------------------------------------------
-- LibEditMode's own dialog, adjusted each time it's built (the library itself stays as it is): its rows end where the
-- dropdowns do, with a slider's value between its name and the slider (ns.ValueBeforeSlider). Reset Settings and Reset
-- Position share a row under the settings, above the divider; the area's own four buttons are two to a row below it.
-- A slider's value is typed in a box the size of the value (LibEditMode's box covers the slider while it's used).

local DIALOG_CONTROL_WIDTH = 160  -- dropdowns and sliders (Edit Mode's 200)
local DIALOG_ROW_WIDTH = 100 + 5 + DIALOG_CONTROL_WIDTH -- a name, the gap and a dropdown (Edit Mode's rows are 330)
local CHECK_WIDTH = 37            -- a checkbox and its gap, before its label
local BUTTON_HEIGHT = 28
local BUTTON_GAP = 5 -- (265 - 5) / 2 gives whole-pixel buttons

local resetRow, grid
local BUTTON_WIDTH = (DIALOG_ROW_WIDTH - BUTTON_GAP) / 2

-- index counts from 0: left, right, then the next row.
local function Put(button, parent, index)
	button:SetParent(parent)
	button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
	button:ClearAllPoints()
	button:SetPoint("TOPLEFT", (index % 2) * (BUTTON_WIDTH + BUTTON_GAP),
		-math.floor(index / 2) * (BUTTON_HEIGHT + BUTTON_GAP))
end

-- The typing box (shown over the value all the time, so it can be clicked) fits inside the value's space, and while
-- it's used the slider stays shown and the value under it is hidden. LibEditMode puts it back over the value and a
-- little past it whenever it's used, so it's fitted again after.
-- It types in the value's own font and colour, centred. Its border (InputBoxTemplate) reaches 5 past the box on the left
-- and not at all on the right, so the box sits 5 further right than its border and its text keeps 5 clear on the right:
-- the border is then centred on the value, and the text centred in the border.
local VALUE_BOX_SPILL = 2 -- how far the border reaches past the value on each side
local VALUE_BOX_ART = 5

local function FitValueBox(box, value)
	box:ClearAllPoints()
	box:SetPoint("TOPLEFT", value, "TOPLEFT", VALUE_BOX_ART - VALUE_BOX_SPILL, 0)
	box:SetPoint("BOTTOMRIGHT", value, "BOTTOMRIGHT", VALUE_BOX_SPILL, 0)
	box:SetFontObject(value:GetFontObject())
	box:SetTextColor(value:GetTextColor())
	box:SetJustifyH("CENTER")
	box:SetTextInsets(0, VALUE_BOX_ART, 0, 0)
end

-- The value to type over: as a person would write it (1.9, not the slider's 1.8999999761581), up to two decimals.
local function TypedValue(value)
	if type(value) ~= "number" then return "" end
	local text = ("%.2f"):format(value)
	text = text:gsub("(%.%d-)0+$", "%1"):gsub("%.$", "")
	return text
end

local function KeepValueBox(widget)
	local box, slider = rawget(widget, "EditBox"), rawget(widget, "Slider")
	if not (box and slider) then return end
	local value = slider.RightText
	if not box.ctxKept then
		box.ctxKept = true
		box:HookScript("OnEditFocusGained", function(self)
			FitValueBox(self, value)
			slider:Show()
			value:SetAlpha(0)
			self:SetText(TypedValue(slider.Slider:GetValue()))
			self:HighlightText()
			-- The click that focused it places the cursor when the button comes up, which clears the selection, so
			-- it's selected again then (only for that click; a later click places the cursor as usual).
			self.ctxSelectOnRelease = true
		end)
		box:HookScript("OnMouseUp", function(self)
			if self.ctxSelectOnRelease and self:HasFocus() then
				self:SetCursorPosition(0)
				self:HighlightText()
			end
			self.ctxSelectOnRelease = nil
		end)
		box:HookScript("OnEditFocusLost", function(self)
			FitValueBox(self, value)
			value:SetAlpha(1)
		end)
	end
	if not box:HasFocus() then FitValueBox(box, value) end
end

-- LibEditMode shows a setting's tooltip (its desc) only while the row itself is hovered, not its dropdown or slider,
-- which cover most of it: those pass hovering on to the row.
local function PassHover(widget)
	if widget.ctxHover then return end
	widget.ctxHover = true
	local function Enter()
		local script = widget:GetScript("OnEnter")
		if script then script(widget) end
	end
	local function Leave()
		local script = widget:GetScript("OnLeave")
		if script then script(widget) end
	end
	local slider = rawget(widget, "Slider")
	for _, child in ipairs({ rawget(widget, "Dropdown"), slider, slider and rawget(slider, "Slider"),
			slider and rawget(slider, "Back"), slider and rawget(slider, "Forward") }) do
		if child and child.HookScript then
			child:HookScript("OnEnter", Enter)
			child:HookScript("OnLeave", Leave)
		end
	end
end

local function Relayout(dialog)
	local settings, buttons = dialog.Settings, dialog.Buttons
	if not (settings and buttons) then return end
	dialogFrame = dialog
	ns.TuckBackground(rawget(dialog, "Border"))
	for _, widget in ipairs(settings.widgets or {}) do
		PassHover(widget)
		local dropdown, slider, check = rawget(widget, "Dropdown"), rawget(widget, "Slider"), rawget(widget, "Button")
		if dropdown then dropdown:SetWidth(DIALOG_CONTROL_WIDTH) end
		if slider then
			ns.ValueBeforeSlider(widget, DIALOG_CONTROL_WIDTH)
			widget:SetWidth(DIALOG_ROW_WIDTH)
			KeepValueBox(widget)
		end
		if check and rawget(widget, "Label") then widget.Label:SetWidth(DIALOG_ROW_WIDTH - CHECK_WIDTH) end
	end
	if rawget(settings, "Divider") then settings.Divider:SetWidth(DIALOG_ROW_WIDTH) end

	-- The two resets, in the settings' own column where LibEditMode put Reset To Default (before the divider).
	local reset, resetPosition = rawget(settings, "ResetButton"), rawget(buttons, "ResetPositionButton")
	if reset and resetPosition then
		resetRow = resetRow or CreateFrame("Frame", nil, settings)
		resetRow:SetParent(settings)
		resetRow.layoutIndex = reset.layoutIndex
		resetRow:SetSize(DIALOG_ROW_WIDTH, BUTTON_HEIGHT)
		resetRow:Show()
		reset:SetText(L.EDITMODE_RESET_SETTINGS)
		resetPosition:SetText(L.EDITMODE_RESET_POSITION)
		Put(reset, resetRow, 0)
		Put(resetPosition, resetRow, 1)
	end

	-- The area's own buttons, straight under the divider.
	grid = grid or CreateFrame("Frame", nil, buttons)
	grid:SetParent(buttons)
	grid.layoutIndex = 1
	grid:Show()
	local list = {}
	for _, child in ipairs({ buttons:GetChildren() }) do
		if child ~= grid and child ~= resetPosition and child:IsShown() and child.layoutIndex then
			list[#list + 1] = child
		end
	end
	table.sort(list, function(a, b) return a.layoutIndex < b.layoutIndex end)
	for index, button in ipairs(list) do Put(button, grid, index - 1) end
	local rows = math.ceil(#list / 2)
	grid:SetSize(DIALOG_ROW_WIDTH, rows * BUTTON_HEIGHT + math.max(rows - 1, 0) * BUTTON_GAP)
	buttons:ClearAllPoints()
	buttons:SetPoint("TOP", settings, "BOTTOM", 0, 0)
	settings:Layout()
	buttons:Layout()
	dialog:Layout()
end

-- LibEditMode makes its dialog when the first frame is added.
local dialogHooked = false
local function HookDialog()
	local dialog = not dialogHooked and LEM.internal and LEM.internal.dialog
	if not dialog then return end
	dialogHooked = true
	hooksecurefunc(dialog, "Update", function(self) ns.SafeCall("EditMode dialog", Relayout, self) end)
end

-- Snapping ------------------------------------------------------------------------------------------------------------
-- LibEditMode leaves snapping undone, so an area snaps as Blizzard's own frames do (EditModeSystemMixin:OnDragStop):
-- when Edit Mode's Snap is on, Blizzard's EditModeMagnetismManager snaps it on drop to the screen's edges and centre,
-- the grid, Blizzard's frames and the other areas, and Blizzard's red preview lines show the snap while dragging. Each
-- holder takes Blizzard's own magnetism methods (its selection covers it, as a system's does). The manager is used
-- through a copy of itself with its own frame list (Blizzard's, plus the other areas), and the preview lines are CTX's
-- own, so nothing is written into Edit Mode: Blizzard's frames never snap to an area, and its layouts never refer to one.

local MAGNETISM_METHODS = {
	"HasValidSelectionRect", "IsToTheLeftOfFrame", "IsToTheRightOfFrame", "IsAboveFrame", "IsBelowFrame",
	"IsVerticallyAlignedWithFrame", "IsHorizontallyAlignedWithFrame", "GetScaledSelectionCenter", "GetScaledCenter",
	"GetScaledSelectionSides", "GetLeftOffset", "GetRightOffset", "GetTopOffset", "GetBottomOffset",
	"GetSelectionOffset", "GetCombinedSelectionOffset", "GetCombinedCenterOffset", "GetSnapOffsets", "SnapToFrame",
	"IsFrameAnchoredToMe", "GetFrameMagneticEligibility",
}

local snapLines, snapLinePool, dragging

local function CanSnap(holder)
	return type(EditModeMagnetismManager) == "table" and holder.ctxMagnetic == true
end

local function SnapEnabled()
	return EditModeManagerFrame and EditModeManagerFrame.IsSnapEnabled and EditModeManagerFrame:IsSnapEnabled()
end

-- Blizzard's magnetism manager, seeing Blizzard's magnetic frames and the other areas with their boxes showing.
local function Magnetism(holder)
	local manager = EditModeMagnetismManager
	local frames = {}
	for frame in pairs(manager.magneticFrames or {}) do frames[frame] = true end
	for other in pairs(registered) do
		local selection = other ~= holder and other.ctxMagnetic and other.Selection
		if selection and selection:IsVisible() and other:HasValidSelectionRect() then frames[other] = true end
	end
	local copy = setmetatable({ magneticFrames = frames }, { __index = manager })
	-- Blizzard measures the screen when Edit Mode opens; measured here too (on the copy) if it hasn't yet.
	if copy.topLevelParentCenterX == nil and manager.UpdateTopLevelParentPoints then
		manager.UpdateTopLevelParentPoints(copy)
	end
	return copy
end

local function HideSnapLines()
	if snapLinePool then snapLinePool:ReleaseAll() end
end

-- Blizzard's preview lines (EditModeManagerFrameMixin:RefreshSnapPreviewLines), on CTX's own frame.
local function RefreshSnapLines()
	HideSnapLines()
	if not (dragging and SnapEnabled()) then return end
	if not snapLinePool then
		if not (EditModeUtil and EditModeUtil.CreateLinePool and MagnetismPreviewLineMixin) then return end
		snapLines = CreateFrame("Frame", nil, UIParent)
		snapLines:SetAllPoints()
		snapLines:SetFrameStrata("DIALOG")
		snapLinePool = EditModeUtil.CreateLinePool(snapLines, "MagnetismPreviewLineTemplate")
	end
	local manager = Magnetism(dragging)
	local infos = manager:GetMagneticFrameInfos(dragging)
	for _, info in ipairs(infos or {}) do
		for _, anchor in ipairs(manager:GetPreviewLineAnchors(info)) do
			snapLinePool:Acquire():Setup(info, anchor)
		end
	end
end

local function UpdateSnapLines()
	ns.SafeCall("EditMode snap lines", RefreshSnapLines)
end

local function StopDragging()
	dragging = nil
	HideSnapLines()
	if snapLines then snapLines:SetScript("OnUpdate", nil) end
end

-- Gives a holder Blizzard's magnetism methods and snaps it when LibEditMode's drag ends, before LibEditMode saves where
-- it is (its OnDragStop reads the position back from the holder, so a snapped one is saved as such).
local function AttachSnapping(holder, selection)
	if type(EditModeSystemMixin) ~= "table" or type(EditModeMagnetismManager) ~= "table" then return end
	for _, name in ipairs(MAGNETISM_METHODS) do
		if type(EditModeSystemMixin[name]) ~= "function" then return end
	end
	for _, name in ipairs(MAGNETISM_METHODS) do holder[name] = EditModeSystemMixin[name] end
	holder.Selection = selection
	holder.ctxMagnetic = true

	local onDragStart, onDragStop = selection:GetScript("OnDragStart"), selection:GetScript("OnDragStop")
	selection:SetScript("OnDragStart", function(self, ...)
		if onDragStart then onDragStart(self, ...) end
		if InCombatLockdown() or not CanSnap(holder) then return end
		dragging = holder
		UpdateSnapLines()
		if snapLines then snapLines:SetScript("OnUpdate", UpdateSnapLines) end
	end)
	selection:SetScript("OnDragStop", function(self, ...)
		local wasDragging = dragging == holder
		StopDragging()
		if wasDragging and not InCombatLockdown() and SnapEnabled() then
			holder:StopMovingOrSizing()
			ns.SafeCall("EditMode snap", function() Magnetism(holder):ApplyMagnetism(holder) end)
		end
		if onDragStop then onDragStop(self, ...) end
	end)
	-- Combat ends LibEditMode's drag through OnEvent, without a drop: no snap, and the lines go.
	selection:HookScript("OnEvent", function() if dragging == holder then StopDragging() end end)
end

-- Registering holders ---------------------------------------------------------------------------------------------------

ns.Listen("AREA_HOLDER", function(area)
	local holder = area and area.holder
	if not holder or not (ns.Areas and ns.Areas.Settings) then return end
	local settings = ns.Areas.Settings(area.id)
	if settings then holder.editModeName = settings.name end
	-- LibEditMode can't unregister a frame and appends buttons on every call, so each holder is registered once.
	if not registered[holder] then
		local default = settings and type(settings.default) == "table" and settings.default or DEFAULT_POSITION
		local proxy = { point = default.point, x = default.x, y = default.y }
		registered[holder] = proxy
		-- No name, so the dialog title and the selection label follow holder.editModeName (renames show).
		LEM:AddFrame(holder, function(...) ns.SafeCall("EditMode moved", OnMoved, ...) end, proxy, nil)
		local selection = LEM.frameSelections and LEM.frameSelections[holder]
		if selection then
			selection:HookScript("OnShow", function(self) if not EditMode.AreasShown() then self:Hide() end end)
			AttachSnapping(holder, selection)
		end
		LEM:AddFrameSettings(holder, BuildSettings(holder))
		LEM:AddFrameSettingsButtons(holder, BuildButtons(holder))
		HookDialog()
	end
	Place(area.id, area)
end)

ns.Listen("AREAS_CHANGED", function(id)
	if not (ns.Areas and ns.Areas.list and ns.Areas.Settings) then return end
	if id ~= nil then
		local area = ns.Areas.list[id]
		if area then Place(id, area) end
		return
	end
	-- Everything changed (a profile or a preset): close the dialog if its area may be gone, else rebuild it.
	PlaceAll()
	local orphan = false
	for holder in pairs(registered) do
		if not AreaOf(holder) then orphan = true end
	end
	if orphan then
		HideDialog()
	else
		for holder in pairs(registered) do LEM:RefreshFrameSettings(holder) end
	end
end)

-- Edit Mode's Combat Text Areas switch --------------------------------------------------------------------------------
-- Every Edit Mode frame can be hidden from Edit Mode's own panel. CTX's areas can't join that panel's list without
-- tainting it (its code, which also targets and focuses units, would then read CTX's values), so the switch sits in a
-- panel of its own docked under Edit Mode's, built from the same border and checkbox. Unticked, the areas' boxes aren't
-- shown or selectable in Edit Mode and get no samples; their text still shows in play. Account-wide, as Edit Mode's
-- own switches are.

local PANEL_HEIGHT = 52
local PANEL_PADDING = 20
local areasPanel

function EditMode.AreasShown()
	return not (ns.global and ns.global.editModeAreas == false)
end

local StartSamples, StopSamples -- below

local function ApplyAreasShown()
	local shown = EditMode.AreasShown()
	for holder in pairs(registered) do
		local selection = LEM.frameSelections and LEM.frameSelections[holder]
		if selection then
			if not shown then
				selection:Hide()
			elseif LEM:IsInEditMode() and selection.ShowHighlighted then
				selection:ShowHighlighted()
			end
		end
	end
	if not shown then
		HideDialog()
		if ns.EventTypes and ns.EventTypes.Close then ns.EventTypes.Close() end
	end
	ns.Fire("EDIT_MODE_AREAS", shown)
	if LEM:IsInEditMode() then
		if shown then StartSamples() else StopSamples() end
	end
end

local function AreasPanel()
	if areasPanel or not EditModeManagerFrame then return areasPanel end
	local panel = CreateFrame("Frame", "CombatTextExtendedEditModePanel", UIParent)
	panel:SetFrameStrata(EditModeManagerFrame:GetFrameStrata())
	panel:SetHeight(PANEL_HEIGHT)
	panel:SetPoint("TOPLEFT", EditModeManagerFrame, "BOTTOMLEFT", 0, 0)
	panel:SetWidth(EditModeManagerFrame:GetWidth())
	panel:EnableMouse(true)
	panel:Hide()
	panel.Border = CreateFrame("Frame", nil, panel, "DialogBorderTranslucentTemplate")
	if ns.TuckBackground then ns.TuckBackground(panel.Border) end
	local check = CreateFrame("Frame", nil, panel, "EditModeManagerSettingCheckButtonTemplate")
	check:ClearAllPoints()
	check:SetPoint("LEFT", panel, "LEFT", PANEL_PADDING, 0)
	check.Label:SetText(L.EDITMODE_SHOW_AREAS)
	check:SetCallback(function(checked, isUserInput)
		if not isUserInput or not ns.global then return end
		ns.global.editModeAreas = checked and true or false
		ns.SafeCall("EditMode areas switch", ApplyAreasShown)
	end)
	panel.Check = check
	areasPanel = panel
	EditMode.areasPanel = panel -- for the test harness
	return panel
end

-- Other addons dock boxes of their own under Edit Mode's window too (Cooldown Manager Centered does). Their boxes are
-- theirs, so the panel can't join one; it goes under the last of them instead: the shown frame whose top is anchored
-- to the bottom of Edit Mode's window, then any anchored to the bottom of that one, and so on.
local function DockedUnder(target, seen)
	for _, parent in ipairs({ UIParent, EditModeManagerFrame }) do
		for _, child in ipairs({ parent:GetChildren() }) do
			-- Only boxes on screen (one shown inside a hidden parent has no place to anchor to).
			if child ~= areasPanel and not seen[child] and not (child.IsForbidden and child:IsForbidden())
					and child:IsVisible() and child:GetBottom() then
				for i = 1, child:GetNumPoints() do
					local ok, point, relativeTo, relativePoint = pcall(child.GetPoint, child, i)
					if ok and relativeTo == target and type(point) == "string" and type(relativePoint) == "string"
							and point:find("TOP") and relativePoint:find("BOTTOM") then
						return child
					end
				end
			end
		end
	end
end

local function Dock()
	local panel = areasPanel
	if not (panel and panel:IsShown()) then return end
	local anchor, seen = EditModeManagerFrame, {}
	for _ = 1, 10 do
		local below = DockedUnder(anchor, seen)
		if not below then break end
		seen[below] = true
		anchor = below
	end
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
	panel:SetWidth(EditModeManagerFrame:GetWidth())
end

-- Docked again a moment later too, for boxes other addons add once Edit Mode is open.
local DOCK_AGAIN = { 0, 0.5, 1.5 }

local function ShowAreasPanel(shown)
	local panel = shown and AreasPanel() or areasPanel
	if not panel then return end
	if shown then panel.Check:SetControlChecked(EditMode.AreasShown()) end
	panel:SetShown(shown)
	if shown then
		ns.SafeCall("EditMode dock", Dock)
		for _, delay in ipairs(DOCK_AGAIN) do
			C_Timer.After(delay, function() ns.SafeCall("EditMode dock", Dock) end)
		end
	end
end

-- Entering and leaving Edit Mode ---------------------------------------------------------------------------------------

local function SampleAll()
	if not (ns.Router and ns.Router.SampleArea) then return end
	for _, id in ipairs(AreaIDs()) do
		ns.Router.SampleArea(id)
	end
end

function StopSamples()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
end

function StartSamples()
	StopSamples()
	if not EditMode.AreasShown() then return end
	ns.SafeCall("EditMode samples", SampleAll)
	ticker = C_Timer.NewTicker(SAMPLE_EVERY, function() ns.SafeCall("EditMode samples", SampleAll) end)
end

-- LibEditMode follows Edit Mode being shown and hidden, so Blizzard briefly hiding it to open another panel gives an
-- exit and then an enter.
LEM:RegisterCallback("enter", function()
	ns.SafeCall("EditMode enter", function()
		ns.Fire("EDIT_MODE_AREAS", EditMode.AreasShown())
		ns.Fire("EDIT_MODE", true)
		ShowAreasPanel(true)
		StartSamples()
		if not EditMode.AreasShown() then ApplyAreasShown() end
	end)
end)

LEM:RegisterCallback("exit", function()
	ns.SafeCall("EditMode exit", function()
		StopSamples()
		ClosePopups()
		ShowAreasPanel(false)
		ns.Fire("EDIT_MODE", false)
	end)
end)

LEM:RegisterCallback("layout", function(...) ns.SafeCall("EditMode layout", OnLayout, ...) end)
LEM:RegisterCallback("rename", function(...) ns.SafeCall("EditMode rename", OnRename, ...) end)
LEM:RegisterCallback("delete", function(...) ns.SafeCall("EditMode delete", OnDelete, ...) end)
LEM:RegisterCallback("create", function(...) ns.SafeCall("EditMode create", OnCreate, ...) end)

-- Nothing stays open in combat (design document 4.2). LibEditMode already refuses drags then.
ns.Listen("COMBAT", function(inCombat)
	if not inCombat then return end
	ClosePopups()
	HideDialog()
end)

-- Opening Edit Mode ----------------------------------------------------------------------------------------------------

-- As Blizzard's /editmode does (SlashCommandsOverrides.lua), and never in combat.
function EditMode.Open()
	if ns.InCombat() then
		SystemMessage(ERR_NOT_IN_COMBAT or L.EDITMODE_IN_COMBAT)
		return false
	end
	if not EditModeManagerFrame:CanEnterEditMode() then
		SystemMessage(ERROR_SLASH_EDITMODE_CANNOT_ENTER or L.EDITMODE_CANNOT_ENTER)
		return false
	end
	ShowUIPanel(EditModeManagerFrame)
	return true
end
