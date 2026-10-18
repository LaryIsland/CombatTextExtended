local addonName, ns = ...
local L = ns.L

-- The Event Types popup (design document 4.8, 4.9). It looks and works like Edit Mode's own settings dialog, and is
-- built from the same parts: Blizzard's translucent dialog border, its title and close button, its setting rows
-- (EditModeSettingDropdownTemplate, EditModeSettingCheckboxTemplate, EditModeSettingSliderTemplate) and its Reset To
-- Default button. Two dropdowns at the top pick a group (or the triggers) and then the event types to set up (ticked,
-- one or several) or one trigger. Below are their settings, with a preview of the first one's text: a change applies
-- to every ticked event, and a setting they don't share shows as mixed (a dash, or "Mixed") until it's set. Opened
-- from the areas' Edit Mode dialogs, the options page and /ctx types; never in combat, and it closes when combat
-- starts or Edit Mode ends.

ns.EventTypes = {}
local EventTypes = ns.EventTypes

local FRAME_NAME = "CombatTextExtendedEventTypes"
local ADD_POPUP = "COMBATTEXTEXTENDED_ADD_TRIGGER"
local DELETE_POPUP = "COMBATTEXTEXTENDED_DELETE_TRIGGER"
local TRIGGERS = "triggers" -- the triggers' page, after the groups

-- Edit Mode's own measurements (Blizzard_EditMode/Shared/EditModeTemplates.xml and EditModeDialogs.xml), with rows
-- ending where the dropdowns do, as in the areas' dialogs (EditMode.lua).
local LABEL_WIDTH = 100
local CONTROL_GAP = 5
local CONTROL_WIDTH = 160 -- dropdowns and sliders (Edit Mode's 200)
local ROW_WIDTH = LABEL_WIDTH + CONTROL_GAP + CONTROL_WIDTH
local ROW_HEIGHT = 32
local EDIT_ART = 5 -- the input box's border reaches this far past the box on each side
local EDIT_X = LABEL_WIDTH + CONTROL_GAP + EDIT_ART + 1
local EDIT_WIDTH = ROW_WIDTH - EDIT_X - EDIT_ART -- its border ends where the dropdowns do
local DIALOG_GAP = 6 -- between this and an area's Edit Mode dialog
local PREVIEW_DEFAULT = 20
local PREVIEW_HEIGHT = 50 -- the preview's space, with the text centred in it: text up to 50 fits, and bigger text
                           -- makes it (and the popup) as tall as the text
local BUTTONS_GAP = 2 -- between the last setting and the buttons
local PREVIEW_ICON_GAP = 4 -- between the preview's icon and its text, as in the areas (Areas.lua ICON_GAP)
local MENU_COLUMNS_FROM = 7 -- the Event dropdown splits its events into two columns from this many
local FLAGS_GAP = 24 -- between Show's box and Sticky's name, on the row they share
local PREVIEW_SPILL = 12 -- how far the preview's text may reach past the rows on each side, short of the border
local SIZE_MIN, SIZE_MAX = -20, 20 -- the text size offset from the area's
local MIXED_MARK = "\226\128\147" -- an en dash: the ticked events differ here (checkboxes, dropdowns, slider, text)
local QUESTION_MARK = 134400

-- What a trigger the player adds starts as (Triggers.Add), for its Reset To Default.
local NEW_TRIGGER = {
	enabled = true, message = false, color = { r = 1, g = 1, b = 0 }, sound = false, area = false, sticky = true,
}

local OUTLINES = {
	{ value = false, text = L.POPUP_DEFAULT },
	{ value = "", text = L.OPT_OUTLINE_NONE },
	{ value = "OUTLINE", text = L.OPT_OUTLINE_THIN },
	{ value = "THICKOUTLINE", text = L.OPT_OUTLINE_THICK },
}

local frame
local rows = {}
EventTypes.rows = rows -- for the test harness, which works the popup through its rows
local page                 -- a group key, or TRIGGERS
local selected = {}        -- per page: a set of ticked type keys, or (triggers) the trigger's settings table
local showAllClasses = false
local refreshQueued = false

-- Data from the other modules ------------------------------------------------------------------------------------------
-- Every other module is called at run time and checked first.

-- r, g, b and the opacity (1 when it has none).
local function RGB(color)
	if type(color) ~= "table" then return 1, 1, 1, 1 end
	return color.r or color[1] or 1, color.g or color[2] or 1, color.b or color[3] or 1, color.a or 1
end

local function Copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, each in pairs(value) do copy[key] = Copy(each) end
	return copy
end

local function Pages()
	local list = {}
	for _, group in ipairs(ns.GROUPS or {}) do
		list[#list + 1] = { key = group.key, label = group.label }
	end
	list[#list + 1] = { key = TRIGGERS, label = L.POPUP_PAGE_TRIGGERS }
	return list
end

local function PageExists(key)
	for _, each in ipairs(Pages()) do
		if each.key == key then return true end
	end
	return false
end

local function TypesOf(groupKey)
	local list = {}
	for _, def in ipairs(ns.TYPES or {}) do
		if def.group == groupKey then list[#list + 1] = def end
	end
	return list
end

local function TypeDef(key) return ns.TYPE and ns.TYPE[key] end

local function TypeSettings(key)
	if ns.Router and ns.Router.TypeSettings then return ns.Router.TypeSettings(key) end
	return ns.profile and ns.profile.types and ns.profile.types[key]
end

local function TypeDefaults(key)
	local defaults = ns.PROFILE_DEFAULTS and ns.PROFILE_DEFAULTS.types
	return defaults and defaults[key]
end

local function AreaIDs()
	if ns.Areas and ns.Areas.Order then return ns.Areas.Order() end
	local ids = {}
	for id in pairs(ns.profile and ns.profile.areas or {}) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local function AreaSettings(id)
	if ns.Areas and ns.Areas.Settings then return ns.Areas.Settings(id) end
	return ns.profile and ns.profile.areas and ns.profile.areas[id]
end

local function AreaName(id)
	local settings = AreaSettings(id)
	return settings and settings.name or tostring(id)
end

-- The area text goes to: its own if it still exists, otherwise the first (as the router does).
local function ResolvedArea(id)
	if id and AreaSettings(id) then return id end
	if ns.Areas and ns.Areas.Fallback then return ns.Areas.Fallback() end
	return AreaIDs()[1]
end

-- The game settings that switch a type off, when they do (nil when it shows). A type behind several switches (power
-- gains) is off only when all of them are.
local function GameSettingsOff(def)
	local cvars = def and (def.gameSettings or (def.gameSetting and { def.gameSetting }))
	if not cvars then return nil end
	for _, cvar in ipairs(cvars) do
		if ns.GameSetting(cvar) then return nil end
	end
	return cvars
end

-- Where the switch is in the game's options, in the game's own words ("Text on Me > Auras Gained/Lost").
local function GameSettingText(cvar)
	local label = ns.GameSettingLabel(cvar)
	if not label then return cvar end
	local menu = _G.FLOATING_COMBAT_TEXT_ON_ME_DROPDOWN_LABEL
	if type(menu) ~= "string" then return label end
	return L.POPUP_GAME_SETTING_PATH:format(menu, label)
end

-- A type's colour, font and outline as they'll show: its own, or the default (Blizzard's colour, the options page's
-- font and outline).
local function TypeColor(def, settings)
	if settings and type(settings.color) == "table" then return RGB(settings.color) end
	return RGB(def and def.color)
end

local function TypeSticky(def, settings)
	local sticky = settings and settings.sticky
	if sticky == "always" then return true end
	if sticky == "never" then return false end
	return def and def.sticky == true or false
end

-- The font file an event's text uses, or nil for the game's combat text font.
local function FontPath(font)
	if font == false or font == nil then font = (ns.profile or {}).font end
	if not font or font == "game" then return nil end
	return ns.Media and ns.Media.FontPath and ns.Media.FontPath(font) or nil
end

local function Outline(outline)
	if outline == false or outline == nil then outline = (ns.profile or {}).outline end
	if outline == "OUTLINE" or outline == "THICKOUTLINE" then return outline end
	return ""
end

-- Triggers: ns.Triggers.List gives { key or index, settings, def, builtin } for each.
local function TriggerList()
	if not (ns.Triggers and ns.Triggers.List) then return {} end
	return ns.Triggers.List(showAllClasses) or {}
end

local function Known(spellID)
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		return C_SpellBook.IsSpellKnown(spellID, Enum.SpellBookSpellBank.Player)
	end
	return false
end

-- A built-in trigger's spell is the first of its ranks the player knows (or its first), a custom one's its own.
local function TriggerSpell(entry)
	local settings, def = entry.settings, entry.def
	if not entry.builtin then return settings and settings.spell end
	local spells = def and def.spells or {}
	for _, id in ipairs(spells) do
		if Known(id) then return id end
	end
	return spells[1]
end

local function SpellName(id)
	local name = id and ns.Readable(C_Spell.GetSpellName(id))
	if type(name) == "string" and name ~= "" then return name end
	return L.POPUP_UNKNOWN_SPELL:format(tonumber(id) or 0)
end

local function SpellIcon(id)
	return id and ns.Readable(C_Spell.GetSpellTexture(id)) or QUESTION_MARK
end

local function KindLabel(kind)
	for _, each in ipairs(ns.TRIGGER_KINDS or {}) do
		if each.key == kind then return each.label end
	end
	return kind
end

-- The text a trigger shows when the player hasn't written one, as Triggers.lua makes it.
local function TriggerDefaultMessage(entry)
	return L.TRIGGERS_MESSAGE:format(SpellName(TriggerSpell(entry)))
end

local function TriggerMessage(entry)
	local message = entry.settings and entry.settings.message
	if type(message) == "string" and message ~= "" then return message end
	return TriggerDefaultMessage(entry)
end

-- A spell from what the player typed: its ID or its name.
local function ResolveSpell(text)
	text = type(text) == "string" and text:match("^%s*(.-)%s*$") or ""
	if text == "" then return nil end
	local info = C_Spell.GetSpellInfo(tonumber(text) or text)
	local id = info and ns.Readable(info.spellID)
	if type(id) == "number" then return id end
	return nil
end

-- The codes a type's template can use, with what each is ("%a amount, %r amount blocked...").
local function CodesText(def)
	local labels = {}
	for _, each in ipairs(ns.TEMPLATE_CODES or {}) do labels[each.code] = each.label end
	local parts = {}
	for _, code in ipairs(def.codes or {}) do
		parts[#parts + 1] = "%" .. code .. " " .. (labels[code] or "")
	end
	return table.concat(parts, ", ")
end

-- A block, absorb or resist's two wordings in Blizzard's messages (full, partial with the damage taken). The player's
-- text is used for one of them (Router.lua FitsForm), so its grey text shows both.
local function TwoForms(def)
	return def and def.partialTemplate and def.gameSetting == "floatingCombatTextDamageReduction_v2"
end

-- With the Remove < > option, as the text shows (Router.Wording).
local function DefaultWording(def)
	local Wording = ns.Router and ns.Router.Wording or function(text) return text end
	if TwoForms(def) then return L.POPUP_TEXT_TWO_FORMS:format(Wording(def.template), Wording(def.partialTemplate)) end
	return def and Wording(def.template) or false
end

-- Selection ------------------------------------------------------------------------------------------------------------

-- The ticked types on the current group's page, in the group's order; the first type when none is.
local function SelectedKeys()
	local set = selected[page]
	if type(set) ~= "table" then
		set = {}
		selected[page] = set
	end
	local keys = {}
	for _, def in ipairs(TypesOf(page)) do
		if set[def.key] then keys[#keys + 1] = def.key end
	end
	if #keys == 0 then
		local first = TypesOf(page)[1]
		if first then
			set[first.key] = true
			keys[1] = first.key
		end
	end
	return keys
end

local function SelectOnly(groupKey, typeKey)
	selected[groupKey] = { [typeKey] = true }
end

local function SelectedTrigger()
	local list = TriggerList()
	local current = selected[TRIGGERS]
	for _, entry in ipairs(list) do
		if entry.settings == current then return entry, list end
	end
	selected[TRIGGERS] = list[1] and list[1].settings
	return list[1], list
end

-- Tooltips ---------------------------------------------------------------------------------------------------------------

local function ShowTooltip(owner, title, ...)
	if not title then return end
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip_SetTitle(GameTooltip, title)
	for i = 1, select("#", ...) do
		local text = select(i, ...)
		if text then GameTooltip_AddNormalLine(GameTooltip, text, true) end
	end
	GameTooltip:Show()
end

-- A row whose ticked events differ (row.mixed) says so under its own tooltip, or under its name if it has none.
local function RowEnter(row)
	if row.mixed then
		-- The row's own lines without gaps (a tooltip function may leave some out as nil), else just its name.
		local lines = {}
		if row.tooltip then
			local own = { row.tooltip() }
			for i = 1, table.maxn(own) do
				if own[i] then lines[#lines + 1] = own[i] end
			end
		end
		if not lines[1] then lines = { row.Label:GetText() } end
		if lines[1] then
			lines[#lines + 1] = L.POPUP_MIXED_TIP
			ShowTooltip(row, unpack(lines))
		end
		return
	end
	if row.tooltip then ShowTooltip(row, row.tooltip()) end
end

local function RowLeave()
	GameTooltip:Hide()
end

-- Refreshing ----------------------------------------------------------------------------------------------------------

local Refresh

-- Redrawn at most once a frame, after whatever changed has finished.
local function RefreshSoon()
	if refreshQueued or not (frame and frame:IsShown()) then return end
	refreshQueued = true
	C_Timer.After(0, function()
		refreshQueued = false
		Refresh()
	end)
end

local function TriggersChanged()
	if ns.Triggers and ns.Triggers.Changed then
		ns.Triggers.Changed()
	else
		ns.Fire("TRIGGERS_CHANGED")
	end
	RefreshSoon()
end

-- Rows -----------------------------------------------------------------------------------------------------------------
-- Each row is one of Edit Mode's own setting rows, so it looks and behaves like theirs. Blizzard's rows call into
-- EditModeSystemSettingsDialog when changed; CTX's own methods on its own rows replace those calls.

local function SetRowEnabled(row, enabled)
	row.Label:SetFontObject(enabled and "GameFontHighlightMedium" or "GameFontDisableMed2")
	for _, key in ipairs({ "Dropdown", "Button", "Slider", "Swatch", "EditBox" }) do
		local control = rawget(row, key)
		if control then
			control:SetEnabled(enabled)
			return
		end
	end
end

local function Radio(root, text, value, current, set)
	return root:CreateRadio(text, function() return current() == value end, function() set(value) end)
end

-- A dash over a checkbox or colour swatch while the ticked events differ there.
local function MixedMark(region)
	local mark = region:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	mark:SetPoint("CENTER")
	mark:SetText(MIXED_MARK)
	mark:Hide()
	return mark
end

-- Dropdowns show a dash while the ticked events differ: nothing in the menu is selected then, so its default text
-- shows.
local function DropdownRow(index, label, generator)
	local row = CreateFrame("Frame", nil, frame.Settings, "EditModeSettingDropdownTemplate")
	row.layoutIndex = index
	row.Label:SetText(label)
	row.Dropdown:SetWidth(CONTROL_WIDTH)
	row.Dropdown:SetDefaultText(MIXED_MARK)
	row:SetScript("OnEnter", RowEnter)
	row:SetScript("OnLeave", RowLeave)
	row.Dropdown:HookScript("OnEnter", function() RowEnter(row) end)
	row.Dropdown:HookScript("OnLeave", RowLeave)
	row.Dropdown:SetupMenu(function(_, root) generator(root) end)
	return row
end

local function CheckboxRow(index, label, onClick)
	local row = CreateFrame("Frame", nil, frame.Settings, "EditModeSettingCheckboxTemplate")
	row.layoutIndex = index
	row.Label:SetText(label)
	row.Label:SetWidth(ROW_WIDTH - ROW_HEIGHT - CONTROL_GAP)
	row.Mark = MixedMark(row.Button)
	function row:OnCheckButtonClick()
		PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
		onClick(self.Button:GetChecked() and true or false)
	end
	row.OnEnter = RowEnter
	row.OnLeave = RowLeave
	return row
end

-- Puts a checkbox row on a shared row, its name (just its text) first and its box after it. CentreFlags places it.
local function InlineCheck(row, container)
	row:SetParent(container)
	row.layoutIndex = nil
	row.Label:ClearAllPoints()
	row.Label:SetPoint("LEFT", row, "LEFT")
	row.Label:SetWidth(math.ceil(row.Label:GetUnboundedStringWidth()) + 2)
	row.Button:ClearAllPoints()
	row.Button:SetPoint("LEFT", row.Label, "RIGHT", 0, 0)
	row:SetSize(row.Label:GetWidth() + ROW_HEIGHT, ROW_HEIGHT)
end

-- The shown ones of Show and Sticky, side by side in the middle of their row.
local function CentreFlags()
	local shown = {}
	if rows.show:IsShown() then shown[#shown + 1] = rows.show end
	if rows.sticky:IsShown() then shown[#shown + 1] = rows.sticky end
	local total = (#shown - 1) * FLAGS_GAP
	for _, row in ipairs(shown) do total = total + row:GetWidth() end
	local x = math.floor((ROW_WIDTH - total) / 2)
	for _, row in ipairs(shown) do
		row:ClearAllPoints()
		row:SetPoint("LEFT", rows.flags, "LEFT", x, 0)
		x = x + row:GetWidth() + FLAGS_GAP
	end
end

-- checked: true, false, or nil when the ticked events differ (unticked with a dash; a click ticks them all).
local function SetCheck(row, checked)
	row.mixed = checked == nil
	row.Button:SetChecked(checked == true)
	row.Mark:SetShown(row.mixed)
end

-- The value beside the slider: a signed offset ("+2", "-4", "+0"), or a dash (at +0) while the ticked events differ.
local function SliderRow(index, label, minValue, maxValue, onChange)
	local row = CreateFrame("Frame", nil, frame.Settings, "EditModeSettingSliderTemplate")
	row.layoutIndex = index
	row.Label:SetText(label)
	row.Label:SetPoint("LEFT")
	function row:OnSliderValueChanged(value)
		if self.initInProgress then return end
		self.mixed = false
		self.Slider:FormatValue(value)
		onChange(math.floor(value + 0.5))
	end
	-- While it's being dragged the popup's redraws leave the slider alone: setting it up again mid-drag stops the drag.
	function row:OnSliderInteractStart() self.interacting = true end
	function row:OnSliderInteractEnd()
		self.interacting = false
		if self.afterInteract then self.afterInteract() end
	end
	-- The template's OnLoad registered Blizzard's own handlers; registering again with the row as their owner
	-- replaces them with the row's.
	row:OnLoad()
	row:SetWidth(ROW_WIDTH)
	ns.ValueBeforeSlider(row, CONTROL_WIDTH)
	row.Slider.MinText:Hide()
	row.Slider.MaxText:Hide()
	row.minValue, row.maxValue = minValue, maxValue
	row.formatters = {
		[MinimalSliderWithSteppersMixin.Label.Right] = CreateMinimalSliderFormatter(
			MinimalSliderWithSteppersMixin.Label.Right, function(value)
				if row.mixed then return MIXED_MARK end
				value = math.floor(value + 0.5)
				return value >= 0 and "+" .. value or tostring(value)
			end),
	}
	row:SetScript("OnEnter", RowEnter)
	row:SetScript("OnLeave", RowLeave)
	return row
end

-- Set up once; after that only moved when its value changed, and never while it's being dragged.
local function SetSlider(row, value, mixed)
	if row.interacting then return end
	value = math.min(math.max(value, row.minValue), row.maxValue)
	row.mixed = mixed and true or false
	row.initInProgress = true
	if row.ready then
		if row.Slider.Slider:GetValue() ~= value then row.Slider:SetValue(value) end
		row.Slider:FormatValue(value)
	else
		row.Slider:Init(value, row.minValue, row.maxValue, row.maxValue - row.minValue, row.formatters)
		row.ready = true
	end
	row.initInProgress = false
end

-- Blizzard's Edit Mode has no colour row; this is built the way LibEditMode builds its own, from the same label and
-- the game's colour swatch.
local function ColourRow(index, label, get, set, reset)
	local row = CreateFrame("Frame", nil, frame.Settings, "ResizeLayoutFrame")
	row.layoutIndex = index
	row.fixedHeight = ROW_HEIGHT
	row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
	row.Label:SetPoint("LEFT")
	row.Label:SetSize(LABEL_WIDTH, ROW_HEIGHT)
	row.Label:SetJustifyH("LEFT")
	row.Label:SetText(label)
	local swatch = CreateFrame("Button", nil, row, "ColorSwatchTemplate")
	swatch:SetSize(ROW_HEIGHT, ROW_HEIGHT)
	swatch:SetPoint("LEFT", row.Label, "RIGHT", CONTROL_GAP, 0)
	swatch:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	swatch:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			reset()
			return
		end
		-- The game's full colour picker, with its opacity slider.
		local r, g, b, a = get()
		a = a or 1
		local function Picked()
			local pr, pg, pb = ColorPickerFrame:GetColorRGB()
			set(pr, pg, pb, ColorPickerFrame:GetColorAlpha())
		end
		ColorPickerFrame:SetupColorPickerAndShow({
			r = r, g = g, b = b, opacity = a, hasOpacity = true,
			swatchFunc = Picked, opacityFunc = Picked,
			cancelFunc = function() set(r, g, b, a) end,
		})
	end)
	swatch:SetScript("OnEnter", function() RowEnter(row) end)
	swatch:SetScript("OnLeave", RowLeave)
	row.Swatch = swatch
	row.Mark = MixedMark(swatch)
	row:SetScript("OnEnter", RowEnter)
	row:SetScript("OnLeave", RowLeave)
	return row
end

-- An edit box row: the game's input box (with grey instructions while it's empty) beside the same label. Enter or
-- clicking away saves; Escape puts back what was there.
local function EditRow(index, label, onSave)
	local row = CreateFrame("Frame", nil, frame.Settings, "ResizeLayoutFrame")
	row.layoutIndex = index
	row.fixedHeight = ROW_HEIGHT
	row.Label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightMedium")
	row.Label:SetPoint("LEFT")
	row.Label:SetSize(LABEL_WIDTH, ROW_HEIGHT)
	row.Label:SetJustifyH("LEFT")
	row.Label:SetText(label)
	local box = CreateFrame("EditBox", nil, row, "InputBoxInstructionsTemplate")
	box:SetSize(EDIT_WIDTH, 20)
	-- The input box's art reaches a few pixels left of the box itself.
	box:SetPoint("LEFT", row, "LEFT", EDIT_X, 0)
	box:SetAutoFocus(false)
	box:SetMaxLetters(120)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEscapePressed", function(self)
		self.reverting = true
		self:SetText(self.saved or "")
		self:ClearFocus()
	end)
	box:HookScript("OnEditFocusLost", function(self)
		if self.reverting then
			self.reverting = nil
			return
		end
		local text = self:GetText() or ""
		if text ~= (self.saved or "") then onSave(text) end
	end)
	box:HookScript("OnEnter", function() RowEnter(row) end)
	box:HookScript("OnLeave", RowLeave)
	box.Instructions:ClearAllPoints()
	box.Instructions:SetPoint("TOPLEFT")
	box.Instructions:SetPoint("BOTTOMRIGHT")
	box.Instructions:SetFontObject(box:GetFontObject() or "ChatFontNormal")
	box.Instructions:SetTextColor(0.35, 0.35, 0.35)
	row.EditBox = box
	row:SetScript("OnEnter", RowEnter)
	row:SetScript("OnLeave", RowLeave)
	return row
end

local function SetEditText(row, text, instructions)
	local box = row.EditBox
	box.saved = text or ""
	if not box:HasFocus() then box:SetText(box.saved) end
	box.Instructions:SetText(instructions or "")
end

local function DialogButton(parent, index, template, text, onClick)
	local button = CreateFrame("Button", nil, parent, template)
	button.layoutIndex = index
	button:SetText(text)
	button:SetScript("OnClick", onClick)
	if button:GetWidth() > ROW_WIDTH then button:SetWidth(ROW_WIDTH) end
	-- In the middle of the rows above (the layout lines its children up on the left).
	button.leftPadding = math.floor((ROW_WIDTH - button:GetWidth()) / 2)
	button.rightPadding = ROW_WIDTH - button:GetWidth() - button.leftPadding
	return button
end

-- Type settings ------------------------------------------------------------------------------------------------------

-- The first ticked type (the preview's, and the tooltips').
local function CurrentType()
	local key = page ~= TRIGGERS and SelectedKeys()[1]
	return key, TypeDef(key), key and TypeSettings(key)
end

-- fn(key, def, settings) for every ticked type.
local function ForSelected(fn)
	if page == TRIGGERS then return end
	for _, key in ipairs(SelectedKeys()) do
		local settings = TypeSettings(key)
		if settings then fn(key, TypeDef(key), settings) end
	end
end

-- What the ticked types share: get(def, settings, key) for each. Returns the value, or nil when they differ.
local function Common(get)
	local value, seen, mixed = nil, false, false
	ForSelected(function(key, def, settings)
		local each = get(def, settings, key)
		if not seen then
			value, seen = each, true
		elseif each ~= value then
			mixed = true
		end
	end)
	if mixed then return nil end
	return value
end

-- Sets a field on every ticked type: to value, or to valueFor(def, settings) when given.
local function SetType(field, value, valueFor)
	ForSelected(function(key, def, settings)
		if valueFor then
			settings[field] = valueFor(def, settings)
		else
			settings[field] = Copy(value)
		end
		ns.Fire("TYPES_CHANGED", key)
	end)
	RefreshSoon()
end

local function ResetType()
	ForSelected(function(key, _, settings)
		local defaults = TypeDefaults(key)
		if not defaults then return end
		for field, value in pairs(defaults) do settings[field] = Copy(value) end
		ns.Fire("TYPES_CHANGED", key)
	end)
	RefreshSoon()
end

-- Trigger settings ---------------------------------------------------------------------------------------------------

local function CurrentTrigger()
	if page ~= TRIGGERS then return nil end
	return (SelectedTrigger())
end

local function SetTrigger(field, value)
	local entry = CurrentTrigger()
	if not entry then return end
	entry.settings[field] = value
	TriggersChanged()
end

local function ResetTrigger()
	local entry = CurrentTrigger()
	if not entry then return end
	local defaults = NEW_TRIGGER
	if entry.builtin then
		local builtin = ns.PROFILE_DEFAULTS and ns.PROFILE_DEFAULTS.triggers and ns.PROFILE_DEFAULTS.triggers.builtin
		defaults = builtin and builtin[entry.key] or NEW_TRIGGER
	end
	for field, value in pairs(defaults) do entry.settings[field] = Copy(value) end
	TriggersChanged()
end

-- Adding and deleting triggers --------------------------------------------------------------------------------------

local function AddFrom(editBox, kind)
	local id = ResolveSpell(editBox:GetText())
	if not id then
		UIErrorsFrame:AddExternalErrorMessage(L.POPUP_SPELL_UNKNOWN)
		return false
	end
	local settings = ns.Triggers and ns.Triggers.Add and ns.Triggers.Add(kind, id)
	if not settings then return false end
	page = TRIGGERS
	selected[TRIGGERS] = settings
	RefreshSoon()
	return true
end

StaticPopupDialogs[ADD_POPUP] = {
	text = L.POPUP_ADD_TRIGGER_PROMPT,
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = true,
	maxLetters = 60,
	OnShow = function(dialog)
		local editBox = dialog:GetEditBox()
		editBox:SetText("")
		editBox:SetFocus()
	end,
	-- Returning true keeps the popup open, so a name the game doesn't know can be corrected.
	OnAccept = function(dialog, kind) return not AddFrom(dialog:GetEditBox(), kind) end,
	EditBoxOnEnterPressed = function(editBox, kind)
		if AddFrom(editBox, kind) then editBox:GetParent():Hide() end
	end,
	EditBoxOnTextChanged = StaticPopup_StandardNonEmptyTextHandler,
	EditBoxOnEscapePressed = StaticPopup_StandardEditBoxOnEscapePressed,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

StaticPopupDialogs[DELETE_POPUP] = {
	text = L.POPUP_DELETE_TRIGGER_PROMPT,
	button1 = DELETE,
	button2 = CANCEL,
	OnAccept = function(_, settings)
		if ns.Triggers and ns.Triggers.Remove then ns.Triggers.Remove(settings) end
		selected[TRIGGERS] = nil
		RefreshSoon()
	end,
	showAlert = true,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function AddTriggerMenu(button)
	MenuUtil.CreateContextMenu(button, function(_, root)
		for _, kind in ipairs(ns.TRIGGER_KINDS or {}) do
			root:CreateButton(kind.label, function()
				StaticPopup_Show(ADD_POPUP, kind.label, nil, kind.key)
			end)
		end
	end)
end

-- Menus ----------------------------------------------------------------------------------------------------------------

local function PageMenu(root)
	for _, each in ipairs(Pages()) do
		Radio(root, each.label, each.key, function() return page end, function(value)
			page = value
			RefreshSoon()
		end)
	end
end

local function Dimmed(text)
	return DISABLED_FONT_COLOR:WrapTextInColorCode(text)
end

local function ItemMenu(root)
	if page == TRIGGERS then
		for _, entry in ipairs(TriggerList()) do
			local text = SpellName(TriggerSpell(entry)) .. " (" .. KindLabel(entry.settings.kind or entry.def.kind) .. ")"
			if entry.settings.enabled == false then text = Dimmed(text) end
			Radio(root, text, entry.settings, function() return selected[TRIGGERS] end, function(value)
				selected[TRIGGERS] = value
				RefreshSoon()
			end)
		end
		return
	end
	-- Ticked events are set up together. A click picks just that event and closes the menu; a right-click (or
	-- Shift-click) ticks or unticks it and leaves the menu open. The last one can't be unticked; All ticks every one,
	-- or back to the first. Long groups are two columns. The game's menu grid fills every cell top to bottom, a column
	-- at a time, so All keeps a row of its own by having an empty cell beside it, then a divider across both columns.
	local types = TypesOf(page)
	SelectedKeys()
	local set = selected[page]
	local grid = #types >= MENU_COLUMNS_FROM
	local perColumn = math.ceil(#types / 2)
	if grid then root:SetGridMode(MenuConstants.VerticalGridDirection, 2) end
	root:CreateCheckbox(L.POPUP_ALL_EVENTS, function() return #SelectedKeys() == #types end, function()
		if #SelectedKeys() == #types then
			SelectOnly(page, types[1].key)
		else
			for _, def in ipairs(types) do set[def.key] = true end
		end
		RefreshSoon()
	end)
	root:CreateDivider()
	for index, def in ipairs(types) do
		if grid and index == perColumn + 1 then
			-- The second column: an empty cell beside All, its half of the divider, then the rest.
			root:CreateSpacer()
			root:CreateDivider()
		end
		local settings = TypeSettings(def.key)
		local off = GameSettingsOff(def)
		local text = def.label
		if (settings and settings.enabled == false) or off then text = Dimmed(text) end
		local box = root:CreateCheckbox(text, function() return set[def.key] == true end, function(_, input)
			local toggle = (input and input.buttonName == "RightButton") or IsShiftKeyDown()
			if not toggle then
				SelectOnly(page, def.key)
				Refresh()
				return MenuResponse.Close
			end
			if not set[def.key] then
				set[def.key] = true
			elseif #SelectedKeys() > 1 then
				set[def.key] = nil
			end
			RefreshSoon()
		end)
		-- Menu buttons are shared by every menu, so right-clicks are taken only while they're this menu's.
		box:AddInitializer(function(button) button:RegisterForClicks("LeftButtonUp", "RightButtonUp") end)
		box:AddResetter(function(button) button:RegisterForClicks("LeftButtonUp") end)
		if grid and index == #types then
			-- Fill the second column to the first's length, so the columns line up.
			for _ = #types - perColumn + 1, perColumn do root:CreateSpacer() end
		end
		if off then
			box:SetTooltip(function(tooltip)
				GameTooltip_SetTitle(tooltip, def.label)
				GameTooltip_AddNormalLine(tooltip, L.POPUP_GAME_SETTING_OFF, true)
				for _, cvar in ipairs(off) do GameTooltip_AddHighlightLine(tooltip, GameSettingText(cvar)) end
			end)
		end
	end
end

local function AreaMenu(root)
	if page == TRIGGERS then
		local entry = CurrentTrigger()
		if not entry then return end
		local function current() return entry.settings.area or false end
		Radio(root, L.POPUP_AREA_SPELL_ALERTS, false, current, function(value) SetTrigger("area", value) end)
		for _, id in ipairs(AreaIDs()) do
			Radio(root, AreaName(id), id, current, function(value) SetTrigger("area", value) end)
		end
		return
	end
	local function current() return Common(function(_, settings) return ResolvedArea(settings.area) end) end
	for _, id in ipairs(AreaIDs()) do
		Radio(root, AreaName(id), id, current, function(value) SetType("area", value) end)
	end
end

local function SoundMenu(root)
	local current
	if page == TRIGGERS then
		local entry = CurrentTrigger()
		if not entry then return end
		current = function() return entry.settings.sound or false end
	else
		current = function() return Common(function(_, settings) return settings.sound or false end) end
	end
	root:SetScrollMode(400)
	for _, sound in ipairs(ns.Media and ns.Media.Sounds and ns.Media.Sounds() or {}) do
		Radio(root, sound.text, sound.value, current, function(value)
			if page == TRIGGERS then SetTrigger("sound", value) else SetType("sound", value) end
			-- Picking a sound plays it, even with sounds turned off in the options, so it can be heard.
			if value and ns.Media and ns.Media.Play then ns.Media.Play(value, true) end
		end)
	end
end

local function FontMenu(root)
	local function current() return Common(function(_, settings) return settings.font or false end) end
	local function set(value) SetType("font", value) end
	root:SetScrollMode(400)
	Radio(root, L.POPUP_DEFAULT, false, current, set)
	Radio(root, L.FONT_GAME, "game", current, set)
	for _, font in ipairs(ns.Media and ns.Media.Fonts and ns.Media.Fonts() or {}) do
		if font.value then Radio(root, font.text, font.value, current, set) end
	end
end

local function OutlineMenu(root)
	local function current() return Common(function(_, settings) return settings.outline or false end) end
	for _, each in ipairs(OUTLINES) do
		Radio(root, each.text, each.value, current, function(value) SetType("outline", value) end)
	end
end

-- Building -------------------------------------------------------------------------------------------------------------

local function BuildRows()
	-- Edit Mode's row templates start hidden; these two always show.
	rows.page = DropdownRow(1, L.POPUP_GROUP, PageMenu)
	rows.page:Show()
	rows.item = DropdownRow(2, L.POPUP_EVENT, ItemMenu)
	rows.item:Show()
	-- One ticked event shows its name; several, how many (or All).
	rows.item.Dropdown:SetSelectionText(function()
		if page == TRIGGERS then return nil end
		local keys = SelectedKeys()
		if #keys == 1 then
			local def = TypeDef(keys[1])
			return def and def.label
		end
		if #keys == #TypesOf(page) then return L.POPUP_ALL_EVENTS end
		return L.POPUP_EVENTS_COUNT:format(#keys)
	end)
	rows.showAll = CheckboxRow(3, L.POPUP_SHOW_ALL_CLASSES, function(checked)
		showAllClasses = checked
		RefreshSoon()
	end)

	local preview = CreateFrame("Frame", nil, frame.Settings)
	preview.layoutIndex = 4
	preview:SetSize(ROW_WIDTH, PREVIEW_HEIGHT)
	preview.Text = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	preview.Text:SetPoint("CENTER")
	preview.Text:SetWidth(ROW_WIDTH + PREVIEW_SPILL * 2)
	preview.Text:SetWordWrap(false)
	preview.Icon = preview:CreateTexture(nil, "ARTWORK")
	rows.preview = preview

	-- Show and Sticky share a row (rows.flags), each its name then its box.
	rows.flags = CreateFrame("Frame", nil, frame.Settings)
	rows.flags.layoutIndex = 10
	rows.flags:SetSize(ROW_WIDTH, ROW_HEIGHT)
	rows.show = CheckboxRow(10, L.POPUP_SHOW, function(checked)
		if page == TRIGGERS then SetTrigger("enabled", checked) else SetType("enabled", checked) end
	end)
	InlineCheck(rows.show, rows.flags)

	rows.spell = EditRow(11, L.POPUP_SPELL, function(text)
		local id = ResolveSpell(text)
		if not id then
			UIErrorsFrame:AddExternalErrorMessage(L.POPUP_SPELL_UNKNOWN)
			RefreshSoon()
			return
		end
		SetTrigger("spell", id)
	end)

	rows.text = EditRow(12, L.POPUP_TEXT, function(text)
		local value = text ~= "" and text or false
		if page == TRIGGERS then SetTrigger("message", value) else SetType("template", value) end
	end)

	rows.area = DropdownRow(13, L.POPUP_AREA, AreaMenu)

	rows.colour = ColourRow(14, L.POPUP_COLOUR,
		function()
			if page == TRIGGERS then
				local entry = CurrentTrigger()
				return RGB(entry and entry.settings.color)
			end
			-- Several ticked: the picker starts from the first one's colour.
			local key, def, settings = CurrentType()
			if ns.Router and ns.Router.PreviewColor and key then return ns.Router.PreviewColor(key) end
			return TypeColor(def, settings)
		end,
		function(r, g, b, a)
			-- Opacity is kept only when it's below full, so a plain colour stays { r, g, b }.
			local color = { r = r, g = g, b = b, a = type(a) == "number" and a < 0.995 and a or nil }
			if page == TRIGGERS then SetTrigger("color", color) else SetType("color", color) end
		end,
		function()
			if page == TRIGGERS then
				local entry = CurrentTrigger()
				local defaults = entry and entry.builtin and ns.PROFILE_DEFAULTS.triggers.builtin[entry.key] or NEW_TRIGGER
				SetTrigger("color", Copy(defaults.color))
			else
				SetType("color", false)
			end
		end)

	rows.font = DropdownRow(15, L.POPUP_FONT, FontMenu)
	rows.outline = DropdownRow(16, L.POPUP_OUTLINE, OutlineMenu)
	rows.size = SliderRow(17, L.POPUP_TEXT_SIZE, SIZE_MIN, SIZE_MAX, function(value) SetType("sizeOffset", value) end)
	rows.size.afterInteract = RefreshSoon

	rows.sticky = CheckboxRow(18, L.POPUP_STICKY, function(checked)
		if page == TRIGGERS then
			SetTrigger("sticky", checked)
			return
		end
		-- Back to "as the game has it" when that's what each now matches, so the default keeps following the game.
		SetType("sticky", nil, function(def)
			if checked == (def and def.sticky == true) then return "blizzard" end
			return checked and "always" or "never"
		end)
	end)
	InlineCheck(rows.sticky, rows.flags)

	rows.sound = DropdownRow(19, L.POPUP_SOUND, SoundMenu)

	rows.reset = DialogButton(frame.Buttons, 1, "EditModeSystemSettingsDialogButtonTemplate", RESET_TO_DEFAULT,
		function()
			if page == TRIGGERS then ResetTrigger() else ResetType() end
		end)
	rows.add = DialogButton(frame.Buttons, 2, "EditModeSystemSettingsDialogExtraButtonTemplate", L.POPUP_ADD_TRIGGER,
		function(self) AddTriggerMenu(self) end)
	rows.delete = DialogButton(frame.Buttons, 3, "EditModeSystemSettingsDialogExtraButtonTemplate",
		L.POPUP_DELETE_TRIGGER, function()
			local entry = CurrentTrigger()
			if entry and not entry.builtin then
				StaticPopup_Show(DELETE_POPUP, SpellName(TriggerSpell(entry)), nil, entry.settings)
			end
		end)
end

local function BuildTooltips()
	rows.item.tooltip = function()
		if page ~= TRIGGERS then return L.POPUP_EVENT, L.POPUP_EVENT_TIP end
	end
	rows.text.tooltip = function()
		if page == TRIGGERS then return nil end
		-- The codes every ticked event can use.
		local codes
		ForSelected(function(_, def)
			if not codes then
				codes = {}
				for _, code in ipairs(def.codes or {}) do codes[#codes + 1] = code end
				return
			end
			local has = {}
			for _, code in ipairs(def.codes or {}) do has[code] = true end
			for i = #codes, 1, -1 do
				if not has[codes[i]] then table.remove(codes, i) end
			end
		end)
		local twoForms = false
		ForSelected(function(_, def) if TwoForms(def) then twoForms = true end end)
		local hasCodes = codes and #codes > 0
		if not (twoForms or hasCodes) then return nil end
		return L.POPUP_TEXT, twoForms and L.POPUP_TEXT_TWO_FORMS_TIP or nil,
			hasCodes and L.POPUP_CODES:format(CodesText({ codes = codes })) or nil
	end
	rows.colour.tooltip = function() return L.POPUP_COLOUR, L.POPUP_COLOUR_TIP end
	rows.font.tooltip = function() return L.POPUP_FONT, L.POPUP_FONT_TIP end
	rows.outline.tooltip = function() return L.POPUP_OUTLINE, L.POPUP_FONT_TIP end
	rows.size.tooltip = function() return L.POPUP_TEXT_SIZE, L.POPUP_TEXT_SIZE_OFFSET_TIP end
	rows.sticky.tooltip = function() return L.POPUP_STICKY, L.POPUP_STICKY_TIP end
	rows.show.tooltip = function()
		if page == TRIGGERS then return nil end
		-- The game's switches that keep any ticked event from showing.
		local lines, seen = {}, {}
		ForSelected(function(_, def)
			for _, cvar in ipairs(GameSettingsOff(def) or {}) do
				if not seen[cvar] then
					seen[cvar] = true
					lines[#lines + 1] = GameSettingText(cvar)
				end
			end
		end)
		if #lines == 0 then return nil end
		return L.POPUP_SHOW, L.POPUP_GAME_SETTING_OFF, unpack(lines)
	end
end

local function CreateDialog()
	frame = CreateFrame("Frame", FRAME_NAME, UIParent, "ResizeLayoutFrame")
	frame:SetSize(300, 350)
	frame.widthPadding, frame.heightPadding = 40, 40
	frame:SetFrameStrata("DIALOG")
	frame:SetFrameLevel(210) -- above LibEditMode's dialog (200), which it opens beside
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:SetDontSavePosition(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	frame.Title = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	frame.Title:SetPoint("TOP", 0, -15)
	frame.Title:SetText(L.POPUP_TITLE)

	frame.Border = CreateFrame("Frame", nil, frame, "DialogBorderTranslucentTemplate")
	frame.Border.ignoreInLayout = true
	ns.TuckBackground(frame.Border)

	frame.CloseButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	frame.CloseButton:SetPoint("TOPRIGHT")
	frame.CloseButton.ignoreInLayout = true

	frame.Settings = CreateFrame("Frame", nil, frame, "VerticalLayoutFrame")
	frame.Settings.spacing = 2
	frame.Settings:SetPoint("TOP", frame.Title, "BOTTOM", 0, -12)

	frame.Buttons = CreateFrame("Frame", nil, frame, "VerticalLayoutFrame")
	frame.Buttons.spacing = 2
	frame.Buttons:SetPoint("TOP", frame.Settings, "BOTTOM", 0, -BUTTONS_GAP)

	frame:SetScript("OnHide", function() GameTooltip:Hide() end)
	table.insert(UISpecialFrames, FRAME_NAME)

	BuildRows()
	BuildTooltips()
end

-- Showing what's selected -------------------------------------------------------------------------------------------

local DETAIL_ROWS = { "flags", "show", "spell", "text", "area", "colour", "font", "outline", "size", "sticky",
	"sound", "reset", "add", "delete" }

-- The rows this redraw shows; the rest are hidden after it. Each row is shown or hidden once, never hidden and shown
-- again: hiding the Text Size slider while it's dragged ends the drag.
local wanted = {}
local function Want(...)
	for i = 1, select("#", ...) do wanted[select(i, ...)] = true end
end

-- The size an event shows at: its area's text size plus its offset.
local function ShownSize(areaID, offset)
	local area = AreaSettings(ResolvedArea(areaID))
	local size = (area and tonumber(area.fontSize) or 25) + (tonumber(offset) or 0)
	return math.max(6, size)
end

-- Drawn as the areas draw it (Areas.SetFont), so it looks the same, at its real size. Its
-- space keeps its height for text up to 50; bigger text makes it (and the popup) taller.
local function SetPreview(text, r, g, b, fontPath, outline, icon, size, alpha)
	local preview = rows.preview
	local fontString = preview.Text
	size = size or PREVIEW_DEFAULT
	ns.Areas.SetFont(fontString, fontPath, outline, size)
	preview:SetHeight(math.max(PREVIEW_HEIGHT, size))
	if (ns.profile or {}).shadow ~= false then
		fontString:SetShadowColor(0, 0, 0, 1)
		fontString:SetShadowOffset(1, -1)
	else
		fontString:SetShadowOffset(0, 0)
	end
	fontString:SetTextColor(r, g, b, alpha or 1)
	fontString:SetText(text or "")
	-- Include Icons in Alignment: the icon and text are centred together (as Areas.lua does for centred lines).
	fontString:ClearAllPoints()
	local shift = icon and (ns.profile or {}).alignIcons and (size + PREVIEW_ICON_GAP) / 2 or 0
	fontString:SetPoint("CENTER", preview, "CENTER", shift, 0)
	preview.Icon:ClearAllPoints()
	if icon then
		preview.Icon:SetTexture(icon)
		preview.Icon:SetSize(size, size)
		preview.Icon:SetPoint("RIGHT", fontString, "CENTER", -(fontString:GetUnboundedStringWidth() / 2) - PREVIEW_ICON_GAP, 0)
		local crop = ns.Areas and ns.Areas.IconCrop and ns.Areas.IconCrop() or 0
		preview.Icon:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
		preview.Icon:Show()
	else
		preview.Icon:Hide()
	end
end

local function RefreshType()
	local key, def, settings = CurrentType()
	if not (def and settings) then
		SetPreview("", 1, 1, 1, nil, "")
		return
	end
	local r, g, b, a = TypeColor(def, settings)
	if ns.Router and ns.Router.PreviewColor then r, g, b, a = ns.Router.PreviewColor(key) end
	SetPreview(ns.Router and ns.Router.PreviewText and ns.Router.PreviewText(key) or "", r, g, b,
		FontPath(settings.font), Outline(settings.outline), def.own and key == "COOLDOWN" and QUESTION_MARK or nil,
		ShownSize(settings.area, settings.sizeOffset), a)

	Want("show", "text", "area", "colour", "font", "outline", "size", "sticky", "sound", "reset")

	-- Show is greyed only when the game keeps every ticked event off.
	local allOff = true
	ForSelected(function(_, each) if not GameSettingsOff(each) then allOff = false end end)
	SetCheck(rows.show, Common(function(_, each) return each.enabled ~= false end))
	SetRowEnabled(rows.show, not allOff)

	-- Text: the shared template; empty with the game's wording in grey when there's none (or "each event's own" when
	-- their wordings differ), and a grey dash when their templates differ.
	local template = Common(function(_, each) return type(each.template) == "string" and each.template or false end)
	rows.text.mixed = template == nil
	local wording = Common(function(each) return DefaultWording(each) end)
	local instructions = template == nil and MIXED_MARK or wording or L.POPUP_TEXT_EACH_DEFAULT
	SetEditText(rows.text, template or "", instructions)

	local colour = Common(function(_, _, each)
		local cr, cg, cb, ca = 1, 1, 1, 1
		if ns.Router and ns.Router.PreviewColor then cr, cg, cb, ca = ns.Router.PreviewColor(each) end
		return ("%.3f %.3f %.3f %.3f"):format(cr, cg, cb, ca or 1)
	end)
	rows.colour.mixed = colour == nil
	rows.colour.Mark:SetShown(colour == nil)
	if colour == nil then
		rows.colour.Swatch:SetColorRGB(0.5, 0.5, 0.5)
	else
		rows.colour.Swatch:SetColorRGB(r, g, b)
	end

	local offset = Common(function(_, each) return tonumber(each.sizeOffset) or 0 end)
	SetSlider(rows.size, offset or 0, offset == nil)
	SetCheck(rows.sticky, Common(function(each, settingsOf) return TypeSticky(each, settingsOf) end))

	rows.area.mixed = Common(function(_, each) return ResolvedArea(each.area) end) == nil
	rows.font.mixed = Common(function(_, each) return each.font or false end) == nil
	rows.outline.mixed = Common(function(_, each) return each.outline or false end) == nil
	rows.sound.mixed = Common(function(_, each) return each.sound or false end) == nil
	for _, name in ipairs({ "area", "font", "outline", "sound" }) do rows[name].Dropdown:GenerateMenu() end
end

local function RefreshTrigger()
	local entry = CurrentTrigger()
	Want("add")
	if not entry then
		SetPreview(L.POPUP_NO_TRIGGERS, 0.5, 0.5, 0.5, nil, "")
		return
	end
	local settings = entry.settings
	local spell = TriggerSpell(entry)
	local r, g, b, a = RGB(settings.color)
	local area = settings.area or (TypeSettings("SPELL_ACTIVE") or {}).area
	SetPreview(TriggerMessage(entry), r, g, b, FontPath(false), Outline(false), SpellIcon(spell),
		ShownSize(area, (TypeSettings("TRIGGER") or {}).sizeOffset), a)

	Want("show", "text", "area", "colour", "sticky", "sound", "reset")
	SetCheck(rows.show, settings.enabled ~= false)
	SetRowEnabled(rows.show, true)
	if not entry.builtin then
		Want("spell")
		SetEditText(rows.spell, SpellName(spell), L.POPUP_SPELL_INPUT)
	end
	SetEditText(rows.text, type(settings.message) == "string" and settings.message or "", TriggerDefaultMessage(entry))
	rows.colour.Swatch:SetColorRGB(r, g, b)
	SetCheck(rows.sticky, settings.sticky ~= false)
	rows.area.Dropdown:GenerateMenu()
	rows.sound.Dropdown:GenerateMenu()
	if not entry.builtin then Want("delete") end
end

function Refresh()
	if not (frame and frame:IsShown()) then return end
	if not page or not PageExists(page) then page = Pages()[1].key end
	local onTriggers = page == TRIGGERS

	rows.page.Dropdown:GenerateMenu()
	rows.item.Label:SetText(onTriggers and L.POPUP_TRIGGER or L.POPUP_EVENT)
	rows.item.Dropdown:GenerateMenu()
	rows.showAll:SetShown(onTriggers)
	rows.showAll.Button:SetChecked(showAllClasses)

	table.wipe(wanted)
	for _, name in ipairs(DETAIL_ROWS) do rows[name].mixed = false end
	rows.colour.Mark:Hide()
	if onTriggers then RefreshTrigger() else RefreshType() end
	if wanted.show or wanted.sticky then Want("flags") end
	for _, name in ipairs(DETAIL_ROWS) do
		if rows[name]:IsShown() ~= (wanted[name] == true) then rows[name]:SetShown(wanted[name] == true) end
	end
	CentreFlags()

	frame.Settings:Layout()
	frame.Buttons:Layout()
	frame:Layout()
end

-- Opening and closing ------------------------------------------------------------------------------------------------

-- Beside the area's Edit Mode dialog when it's open, as LibEditMode's own dialogs sit beside Blizzard's.
local function Place()
	frame:ClearAllPoints()
	local dialog = ns.EditMode and ns.EditMode.Dialog and ns.EditMode.Dialog()
	if dialog and dialog:IsShown() then
		frame:SetPoint("TOPRIGHT", dialog, "TOPLEFT", -DIALOG_GAP, 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
	end
end

-- The first group with a type in the area, and that type.
local function FirstInArea(areaID)
	for _, group in ipairs(ns.GROUPS or {}) do
		for _, def in ipairs(TypesOf(group.key)) do
			local settings = TypeSettings(def.key)
			if settings and ResolvedArea(settings.area) == areaID then return group.key, def.key end
		end
	end
	return nil
end

function EventTypes.Open(areaID, pageKey)
	if ns.InCombat() then
		UIErrorsFrame:AddExternalErrorMessage(ERR_NOT_IN_COMBAT)
		return false
	end
	if not frame then CreateDialog() end
	if pageKey and PageExists(pageKey) then
		page = pageKey
	elseif areaID then
		local group, key = FirstInArea(areaID)
		if group then
			page = group
			SelectOnly(group, key)
		end
	end
	Place()
	frame:Show()
	Refresh()
	return true
end

function EventTypes.Close()
	if frame then frame:Hide() end
end

ns.Listen("COMBAT", function(inCombat) if inCombat then EventTypes.Close() end end)
ns.Listen("EDIT_MODE", function(active) if not active then EventTypes.Close() end end)
for _, name in ipairs({ "TYPES_CHANGED", "AREAS_CHANGED", "TRIGGERS_CHANGED", "SETTINGS_CHANGED",
	"GAME_SETTING_CHANGED" }) do
	ns.Listen(name, RefreshSoon)
end
