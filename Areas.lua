local addonName, ns = ...
local L = ns.L

-- Areas (design document 4.1). Each area has:
--   a holder: a fixed-size frame (parent UIParent, named CombatTextExtendedArea<n>) that Edit Mode moves (EditMode.lua)
--     and whose box the text moves in; never sized from text;
--   an engine: a child frame with Blizzard's CombatTextMixin mixed in, so Blizzard's own code adds, stacks, staggers,
--     grows, shrinks, fades and releases every line. It has its own font strings, its OnUpdate is Blizzard's, and two
--     of its methods are CTX's own (UpdateDisplayedMessages for where text goes, InitializeFontString for how it
--     looks). Blizzard's CombatText frame itself is never touched here.
-- The engine is scaled to the area's text size, so Blizzard's heights (25 for text, 30 to 60 for a crit) become the
-- area's sizes.
--
-- Blizzard's font string pool resets with SetToDefaults, which is protected (2.1), so each engine has an unsecured
-- pool of its own that resets with ClearText (which also removes a hidden text's secret aspect), Hide, ClearAllPoints
-- and SetAlpha.
--
--   ns.Areas.list[areaID] = { id, holder, engine, label }   label: the note shown in Edit Mode when CTX can't show text

local Areas = { list = {} }
ns.Areas = Areas

local MAX_LINES = 20             -- Blizzard's CombatTextConstants.NumCombatTextLines
local MESSAGE_HEIGHT = 25        -- Blizzard's MessageHeight: the engine's scale maps it to the area's text size
local CRIT_START_HEIGHT = 30     -- Blizzard's CriticalHitMinHeight: a crit's height as AddMessage leaves it
local FONT_HEIGHT = 64           -- CombatTextFont's own height; SetTextHeight scales from it
local STAND_IN = "0"             -- readable text Blizzard's AddMessage measures in place of hidden text (Areas.Add)
local ICON_GAP = 4
local MIN_TEXT_SIZE = 6         -- a type's size offset never takes text below this
local NO_SHIFT = 1e9            -- a stack Blizzard never reaches, so it never shifts a line sideways
local ICON_ZOOM = 16 -- the options page's icon zoom: the percent of an icon cut off, half from each side
local SCT_SETTING = "enableFloatingCombatText"

-- Blizzard's own area (the default one, Presets.lua), for anything a saved area lacks.
local DEFAULTS = {
	name = "Combat Text", width = 300, height = 250, style = "blizzard", direction = "up", behavior = false,
	stickyStyle = "blizzard", stickyBehavior = false, align = "center", duration = 1.9, stickyDuration = 1.9,
	fontSize = 25, icons = "left", stagger = true, overflow = "shift",
}
-- Where a new area starts in a layout it hasn't been placed in: beside Blizzard's, so the two don't overlap.
local NEW_AREA_POSITION = { point = "CENTER", x = 350, y = 0 }
-- Blizzard's own place for its text (Presets.lua explains the numbers).
local DEFAULT_POSITION = { point = "BOTTOM", x = 0, y = 295 }

local JUSTIFY = { left = "LEFT", center = "CENTER", right = "RIGHT" }

local records = {}       -- every holder made this session, in creation order
local spare = {}         -- holders of deleted areas, waiting to be reused
local order              -- cached Order(), nil when out of date
local editing = false    -- Edit Mode is open
local hiddenInEditMode = false -- the Edit Mode panel's Combat Text Areas is unticked (EditMode.lua)
local reportedAddError = false

local function Value(settings, field)
	local value = settings and settings[field]
	if value == nil then return DEFAULTS[field] end
	return value
end

local function Wipe(t)
	for key in pairs(t) do t[key] = nil end
end

function Areas.Ready()
	return type(CombatTextMixin) == "table" and type(CombatTextMixin.AddMessage) == "function"
		and type(CombatTextMixin.OnUpdate) == "function" and type(CombatTextUtil) == "table"
end

function Areas.Settings(id)
	local areas = ns.profile and ns.profile.areas
	return areas and id ~= nil and areas[id] or nil
end

-- Order ----------------------------------------------------------------------------------------------------------------

-- Area IDs by name, Blizzard's own ("main") first.
local function SortedIDs()
	local areas = ns.profile and ns.profile.areas or {}
	local ids = {}
	for id in pairs(areas) do ids[#ids + 1] = id end
	table.sort(ids, function(a, b)
		if a == "main" or b == "main" then return a == "main" and b ~= "main" end
		local nameA = tostring(Value(areas[a], "name")):lower()
		local nameB = tostring(Value(areas[b], "name")):lower()
		if nameA ~= nameB then return nameA < nameB end
		return tostring(a) < tostring(b)
	end)
	return ids
end

local function CurrentOrder()
	if not order then order = SortedIDs() end
	return order
end

-- A copy, so callers can keep or change it.
function Areas.Order()
	local copy = {}
	for i, id in ipairs(CurrentOrder()) do copy[i] = id end
	return copy
end

function Areas.Fallback()
	return CurrentOrder()[1]
end

-- Font strings ---------------------------------------------------------------------------------------------------------

local function ResetIcon(_, icon)
	icon:Hide()
	icon:ClearAllPoints()
	icon:SetTexture(nil)
	icon:SetAlpha(1)
end

local function ResetLine(_, line)
	if line.ClearText then
		line:ClearText()
	else
		line:SetText("")
	end
	line:Hide()
	line:ClearAllPoints()
	line:SetAlpha(0)
	line.isCrit = nil
	local icon = line.ctxIcon
	if icon then
		line.ctxIcon = nil
		local engine = line:GetParent()
		local pool = engine and engine.ctxIcons
		if pool then pool:Release(icon) end
	end
	if line.ctx then Wipe(line.ctx) end
end

-- Fonts ------------------------------------------------------------------------------------------------------------------
-- Blizzard's CombatTextFont (and CombatTextFontOutline, its thick outline) is a 64 px font drawn smoothly at any text
-- height (filter and fixedSize in Fonts.xml), so SetTextHeight can size lines and grow crits. Only XML can give a font
-- that: SetFont, even on a copy of CombatTextFont, loses it, and scaled text then looks jagged (beta check 24). So any
-- other face or outline is made at each size it's shown at (as MSBT does), one Font object per face, outline and
-- whole height, and Areas.SetHeight picks the one for a height instead of scaling.

local fontObjects = {}
local fontCount = 0

-- path: a font file, or nil for the game's combat text font. outline: "", "OUTLINE" or "THICKOUTLINE". height: the
-- size to make a non-game font at (64, the game font's own, without one).
function Areas.FontObject(path, outline, height)
	outline = (outline == "OUTLINE" or outline == "THICKOUTLINE") and outline or ""
	-- A shared font that's gone comes back as the game's (Media.FontPath).
	if path == CombatTextFont:GetFont() then path = nil end
	if not path and outline == "" then return CombatTextFont end
	if not path and outline == "THICKOUTLINE" and type(CombatTextFontOutline) == "table" then return CombatTextFontOutline end
	path = path or CombatTextFont:GetFont()
	height = height and math.max(1, math.floor(height + 0.5)) or FONT_HEIGHT
	local key = path .. "|" .. outline .. "|" .. height
	local object = fontObjects[key]
	if object == nil then
		fontCount = fontCount + 1
		object = CreateFont(addonName .. "Font" .. fontCount)
		object:CopyFontObject(CombatTextFont)
		local ok, set = pcall(function() return object:SetFont(path, height, outline) end)
		if not ok or set == false then object = false end
		fontObjects[key] = object
	end
	return object or CombatTextFont
end

local function SetShadow(line, on)
	line.ctxShadow = on
	if on then
		line:SetShadowColor(0, 0, 0, 1)
		line:SetShadowOffset(1, -1)
	else
		line:SetShadowOffset(0, 0)
	end
end

local function ApplyShadow(engine, line)
	local font = engine.ctxFont
	SetShadow(line, not (font and not font.shadow))
end

-- A font string's height. The game's own fonts scale smoothly; any other font gets the object made at that size (the
-- text height set to the same, in case the last one stays on the font string).
function Areas.SetHeight(fontString, height)
	if fontString.ctxSized then
		local object = Areas.FontObject(fontString.ctxFontPath, fontString.ctxFontOutline, height)
		if fontString.ctxObject ~= object then
			fontString.ctxObject = object
			fontString:SetFontObject(object)
			if fontString.ctxShadow ~= nil then SetShadow(fontString, fontString.ctxShadow) end
		end
		height = math.max(1, math.floor(height + 0.5))
	end
	fontString:SetTextHeight(height)
end

-- A font string's face and outline (path nil for the game's font), at a height.
function Areas.SetFont(fontString, path, outline, height)
	local object = Areas.FontObject(path, outline)
	fontString.ctxFontPath, fontString.ctxFontOutline = path, outline
	fontString.ctxSized = object ~= CombatTextFont and object ~= CombatTextFontOutline
	fontString.ctxObject = object
	fontString:SetFontObject(object)
	Areas.SetHeight(fontString, height)
end

-- A line's SetAlpha, scaled by its colour's opacity (ctxOpacity, set in Areas.Add): Blizzard shows a line at 1 and
-- fades it from 1 to 0 with SetAlpha, so the opacity holds through the fade instead of jumping back to full.
local function OpacitySetAlpha(line, alpha)
	return line.ctxRawSetAlpha(line, alpha * (line.ctxOpacity or 1))
end

-- CTX's own InitializeFontString (Blizzard's sets CombatTextFont): the profile's font, outline and shadow, a fixed
-- width with no wrapping, and the area's alignment, so left and right aligned text lines up without being measured.
local function InitializeFontString(engine, line)
	if not rawget(line, "ctxRawSetAlpha") then
		line.ctxRawSetAlpha = line.SetAlpha
		line.SetAlpha = OpacitySetAlpha
	end
	line.ctxOpacity = nil
	local font = engine.ctxFont
	-- Blizzard's pool reset puts the text height back to the font's own (SetToDefaults), and its AddMessage measures
	-- the line before setting its height, so every new line starts from the same place. CTX's reset can't use that
	-- (it's protected), so the height goes back here.
	Areas.SetFont(line, font and font.path, font and font.outline, FONT_HEIGHT)
	ApplyShadow(engine, line)
	line:SetWidth(ns.Styles.LINE_WIDTH)
	line:SetWordWrap(false)
	line:SetJustifyH(JUSTIFY[engine.ctxAlign] or "CENTER")
	line:SetAlpha(0)
	local locations = engine.textLocations
	line:SetPoint("TOP", WorldFrame, "BOTTOM", locations.startX, locations.startY)
end

local function ReleaseAll(engine)
	local active = engine.activeFontStrings
	for i = #active, 1, -1 do
		engine:ReleaseFontString(active[i])
	end
end

-- Geometry -------------------------------------------------------------------------------------------------------------

-- The holder's box in the units lines are placed in: offsets from WorldFrame's bottom centre, in the engine's scale
-- (font strings are the engine's regions, so they have its effective scale).
local function Measure(record)
	local engine, holder = record.engine, record.holder
	local geom = engine.ctxGeom
	local scale = engine:GetEffectiveScale()
	local holderScale = holder:GetEffectiveScale() / scale
	local worldScale = WorldFrame:GetEffectiveScale() / scale
	local left, right, bottom, top = holder:GetLeft(), holder:GetRight(), holder:GetBottom(), holder:GetTop()
	local worldLeft, worldRight, worldBottom = WorldFrame:GetLeft(), WorldFrame:GetRight(), WorldFrame:GetBottom()
	if not (left and right and bottom and top and worldLeft and worldRight and worldBottom) then
		-- Not placed yet: the middle of the screen, until Edit Mode places it.
		local width, height = holder:GetWidth() * holderScale, holder:GetHeight() * holderScale
		local middle = (UIParent:GetHeight() * UIParent:GetEffectiveScale() / scale) / 2
		left, right = -width / 2, width / 2
		bottom, top = middle, middle + height
	else
		local originX = (worldLeft + worldRight) / 2 * worldScale
		local originY = worldBottom * worldScale
		left, right = left * holderScale - originX, right * holderScale - originX
		bottom, top = bottom * holderScale - originY, top * holderScale - originY
	end
	geom.left, geom.right, geom.bottom, geom.top = left, right, bottom, top
	geom.width, geom.height = right - left, top - bottom
	geom.centerX = (left + right) / 2
end

-- How far below its start point Blizzard's AddMessage starts a line going up: it stacks from the new line's GetBottom,
-- taken while the line is still at the height InitializeFontString gives it (the font's own, 64), so the line starts
-- that line's height lower. Styles.Layout moves the start and end points up by as much, so lines run inside the box.
-- Measured on a spare font string with the area's font and a readable stand-in, as fonts differ in line height.
local function MeasureDrop(engine)
	local probe = engine.ctxProbe
	if not probe then
		probe = engine:CreateFontString(nil, "BACKGROUND")
		probe:Hide()
		engine.ctxProbe = probe
	end
	local font = engine.ctxFont
	probe:SetFontObject(Areas.FontObject(font.path, font.outline))
	probe:SetTextHeight(FONT_HEIGHT)
	probe:SetText(STAND_IN)
	local height = probe:GetStringHeight()
	if ns.IsSecret(height) or type(height) ~= "number" or height <= 0 then height = FONT_HEIGHT end
	engine.ctxDrop = height
end

-- CTX's own UpdateDisplayedMessages. Blizzard's OnUpdate calls it whenever WorldFrame's size no longer matches
-- textScaleX/Y, so those are kept as Blizzard works them out; Blizzard's spacing between stacked lines scales the same
-- way. Unlike Blizzard's, it never sets the combat text unit or Blizzard's per-type switches.
local function UpdateDisplayedMessages(engine)
	engine.textScaleY = WorldFrame:GetHeight() / 768
	engine.textScaleX = WorldFrame:GetWidth() / 1024
	engine.textSpacing = 10 * engine.textScaleY
	-- When Busy "stack": the sideways shift never comes (Blizzard shifts once the stack reaches 130 below the start).
	local overflow = Value(engine.ctxSettings, "overflow")
	engine.textOffsetMax = overflow == "stack" and NO_SHIFT or 130 * engine.textScaleY
	engine.textOffsetAdjustment = 80 * engine.textScaleX
	local record = engine.ctxArea
	if record then Measure(record) end
	MeasureDrop(engine)
	ns.Styles.Layout(engine)
	ReleaseAll(engine)
end

-- Fonts ------------------------------------------------------------------------------------------------------------------

local function UpdateFont(engine)
	local profile = ns.profile or {}
	local font = engine.ctxFont
	font.path = profile.font and ns.Media and ns.Media.FontPath and ns.Media.FontPath(profile.font) or nil
	local outline = profile.outline
	font.outline = (outline == "OUTLINE" or outline == "THICKOUTLINE") and outline or ""
	font.shadow = profile.shadow ~= false
end

-- Engines ----------------------------------------------------------------------------------------------------------------

-- Blizzard's AddMessage starts a new line below every line still near the start (above, going down), so a crit staying
-- there would push moving text down past it. CTX stacks sticky and moving lines apart: while Areas.Add calls
-- AddMessage, engine.ctxStacking is the new line's kind (sticky or not) and only lines of that kind are listed.
local stackingList = {}
local function EnumerateActiveFontStrings(engine)
	local kind = engine.ctxStacking
	if kind == nil then return ipairs(engine.activeFontStrings) end
	for i = #stackingList, 1, -1 do stackingList[i] = nil end
	for _, line in ipairs(engine.activeFontStrings) do
		local ctx = line.ctx
		if ((ctx and ctx.sticky) or false) == kind then stackingList[#stackingList + 1] = line end
	end
	return ipairs(stackingList)
end

local LineScroll -- below: every line's scroll function

local function MakeEngine(record)
	if record.engine or not Areas.Ready() then return record.engine end
	local engine = CreateFrame("Frame", nil, record.holder)
	engine:SetSize(10, 10)
	engine:SetPoint("CENTER")
	Mixin(engine, CombatTextMixin)
	-- CTX's own methods, on CTX's own frame.
	engine.UpdateDisplayedMessages = UpdateDisplayedMessages
	engine.InitializeFontString = InitializeFontString
	engine.EnumerateActiveFontStrings = EnumerateActiveFontStrings
	engine.activeFontStrings = {}
	engine.textLocations = { startX = 0, startY = 0, endX = 0, endY = 0 }
	engine.textSpacing, engine.textOffsetMax, engine.textOffsetAdjustment = 10, 130, 80
	engine.textScaleX, engine.textScaleY = 1, 1
	engine.xDir = 1
	engine.scrollFunction = LineScroll
	engine.ctxGeom = { left = 0, right = 0, bottom = 0, top = 0, centerX = 0, width = 0, height = 0 }
	engine.ctxState = {}
	engine.ctxFont = {}
	engine.ctxArea = record
	engine.fontStringPool = CreateUnsecuredFontStringPool(engine, "BACKGROUND", nil, nil, ResetLine, MAX_LINES)
	engine.ctxIcons = CreateUnsecuredTexturePool(engine, "ARTWORK", nil, nil, ResetIcon, MAX_LINES)
	engine:SetScript("OnUpdate", CombatTextMixin.OnUpdate)
	record.engine = engine
	return engine
end

-- Holders ----------------------------------------------------------------------------------------------------------------

local function NewRecord()
	local n = #records + 1
	local holder = CreateFrame("Frame", "CombatTextExtendedArea" .. n, UIParent)
	holder:SetSize(DEFAULTS.width, DEFAULTS.height)
	holder:Hide()
	local note = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	note:SetPoint("TOPLEFT", 8, -8)
	note:SetPoint("BOTTOMRIGHT", -8, 8)
	note:SetJustifyH("CENTER")
	note:SetJustifyV("MIDDLE")
	note:SetWordWrap(true)
	note:Hide()
	local record = { holder = holder, label = note, n = n }
	records[n] = record
	MakeEngine(record)
	-- Hidden (Alt+Z, CTX turned off, the area deleted): its lines go, as Blizzard clears its own when its frame isn't
	-- visible, so they don't come back frozen.
	holder:SetScript("OnHide", function()
		local engine = record.engine
		if engine and engine.activeFontStrings then ReleaseAll(engine) end
	end)
	return record
end

local function TakeRecord(id)
	local record = table.remove(spare, 1) or NewRecord()
	record.id = id
	return record
end

local function Retire(record)
	if record.engine then ReleaseAll(record.engine) end
	record.holder:Hide()
	record.id = nil
	spare[#spare + 1] = record
end

-- Positioning is Edit Mode's (EditMode.lua). A holder it hasn't placed yet (EditMode.lua missing or not ready) goes
-- to the area's default, so text still shows somewhere sensible.
local function EnsurePlaced(record, settings)
	local holder = record.holder
	if holder:GetNumPoints() > 0 then return end
	local position = type(settings.default) == "table" and settings.default or DEFAULT_POSITION
	holder:SetPoint(position.point or "CENTER", UIParent, position.point or "CENTER", position.x or 0, position.y or 0)
end

function Areas.Relayout(id)
	local record = Areas.list[id]
	local engine = record and record.engine
	if engine then engine:UpdateDisplayedMessages() end
end

local function RelayoutAll()
	for id in pairs(Areas.list) do Areas.Relayout(id) end
end

-- The area's settings on its holder and engine.
local function Apply(record)
	local settings = Areas.Settings(record.id)
	if not settings then return end
	local holder = record.holder
	holder:SetSize(math.max(1, Value(settings, "width")), math.max(1, Value(settings, "height")))
	EnsurePlaced(record, settings)
	local engine = MakeEngine(record)
	if not engine then return end
	local fontSize = Value(settings, "fontSize")
	if type(fontSize) ~= "number" or fontSize <= 0 then fontSize = DEFAULTS.fontSize end
	engine:SetScale(fontSize / MESSAGE_HEIGHT)
	engine.ctxSettings = settings
	engine.ctxFontSize = fontSize
	UpdateFont(engine)
	engine:UpdateDisplayedMessages()
end

-- Showing ----------------------------------------------------------------------------------------------------------------

local function Active()
	return ns.Router and ns.Router.Active and ns.Router.Active() or false
end

-- Why CTX can't show text right now, for the note in Edit Mode; nil when it can.
local function NoteText()
	if Active() then return nil end
	local profile = ns.profile
	if profile and profile.enabled == false then return L.AREA_NOTE_OFF end
	if ns.GameSetting(SCT_SETTING) and not Areas.Ready() then return L.AREA_NOTE_NOT_LOADED end
	local name = type(SHOW_COMBAT_TEXT_TEXT) == "string" and SHOW_COMBAT_TEXT_TEXT or L.AREA_SETTING_NAME
	return L.AREA_NOTE_SETTING:format(name)
end

-- Holders show while CTX is on (an engine only runs while its holder is shown) or Edit Mode is open with the areas
-- ticked in its panel.
function Areas.UpdateVisibility()
	local active = Active()
	local placing = editing and not hiddenInEditMode
	local note = placing and NoteText() or nil
	for _, record in pairs(Areas.list) do
		record.holder:SetShown(active or placing)
		if note then
			record.label:SetText(note)
			record.label:Show()
		else
			record.label:Hide()
		end
		if not active and record.engine then ReleaseAll(record.engine) end
	end
end

-- Rebuilding -------------------------------------------------------------------------------------------------------------

-- After AREAS_CHANGED (changedID nil: everything): holders for new areas (a spare one if there is one), holders of
-- deleted areas put aside, and settings applied (all of them, or only the changed area's).
function Areas.Rebuild(changedID)
	if not ns.profile then return end
	order = nil
	for id, record in pairs(Areas.list) do
		if not Areas.Settings(id) then
			Areas.list[id] = nil
			Retire(record)
		end
	end
	for _, id in ipairs(CurrentOrder()) do
		local record = Areas.list[id]
		local new = record == nil
		if new then
			record = TakeRecord(id)
			Areas.list[id] = record
		end
		if new or changedID == nil or changedID == id then Apply(record) end
		-- EditMode.lua registers and places it (a reused holder is placed again for its new area).
		if new then ns.Fire("AREA_HOLDER", record) end
	end
	Areas.UpdateVisibility()
end

-- Adding text ------------------------------------------------------------------------------------------------------------

-- Every line's scroll function: the line's style (normal or sticky) does the moving; this keeps the icon faded with
-- its text and gives a Blizzard crit the area's crit size once Blizzard's grow and shrink is over (it clears isCrit).
LineScroll = function(engine, line)
	local ctx = line.ctx
	local scroll = ctx and ctx.scroll
	local x, y
	if scroll then
		x, y = scroll(engine, line)
	else
		x, y = CombatTextUtil.StandardScroll(engine, line)
	end
	if ctx and ctx.ownPop and not ctx.sized then
		-- Blizzard's grow and shrink (CombatTextMixin:OnUpdate), for fonts made at each size.
		local t, low, high = line.scrollTime or 0, CombatTextConstants.CriticalHitMinHeight, CombatTextConstants.CriticalHitMaxHeight
		local grow, shrink = CombatTextConstants.CriticalHitScaleTime, CombatTextConstants.CriticalHitShrinkTime
		if t <= grow then
			Areas.SetHeight(line, math.floor(low + (high - low) * t / grow))
		elseif t <= shrink then
			Areas.SetHeight(line, math.floor(high - (high - low) * (t - grow) / (shrink - grow)))
		else
			Areas.SetHeight(line, ctx.h)
			ctx.sized = true
		end
	elseif ctx and ctx.blizzardPop and not ctx.sized and not line.isCrit then
		Areas.SetHeight(line, ctx.h)
		ctx.sized = true
	end
	local icon = line.ctxIcon
	if icon then icon:SetAlpha(ns.Styles.FadeAlpha(line.scrollTime) * (ctx and ctx.alpha or 1)) end
	return x + (ctx and ctx.iconShift or 0), y
end

-- The icon beside the line's text. Lines are wider than their text, so for a side the alignment doesn't fix (the left
-- side of right-aligned text, either side of centred text) the text's width is needed; CTX's own text (the only text
-- with icons) is readable, but if the width is hidden the icon is left out.
local function AddIcon(engine, line, texture, settings)
	local ctx = line.ctx
	local side = Value(settings, "icons") == "right" and "right" or "left"
	local half = ns.Styles.LINE_WIDTH / 2
	local width
	if not ((ctx.align == "left" and side == "left") or (ctx.align == "right" and side == "right")) then
		width = line:GetStringWidth()
		if ns.IsSecret(width) or type(width) ~= "number" then return end
	end
	local x
	if side == "left" then
		local textLeft = ctx.align == "left" and -half or ctx.align == "right" and (half - width) or -width / 2
		x = textLeft - ICON_GAP
	else
		local textRight = ctx.align == "right" and half or ctx.align == "left" and (-half + width) or width / 2
		x = textRight + ICON_GAP
	end
	local icon = engine.ctxIcons:Acquire()
	if not icon then return end
	icon:SetTexture(texture)
	local crop = Areas.IconCrop()
	icon:SetTexCoord(crop, 1 - crop, crop, 1 - crop)
	icon:SetSize(ctx.h, ctx.h)
	icon:ClearAllPoints()
	icon:SetPoint(side == "left" and "RIGHT" or "LEFT", line, "CENTER", x, 0)
	icon:SetAlpha(1)
	icon:Show()
	line.ctxIcon = icon
	-- Include Icons in Alignment: the icon and text are aligned together, so centred text moves half the icon's width
	-- away from it, and text aligned to the icon's side moves the whole width.
	if (ns.profile or {}).alignIcons then
		local room = ctx.h + ICON_GAP
		local toward = side == "left" and 1 or -1
		if ctx.align == "center" then
			ctx.iconShift = toward * room / 2
		elseif ctx.align == side then
			ctx.iconShift = toward * room
		end
	end
end

-- How much of each side of an icon is cut off (the options page's Zoom), for lines and the options page's example.
function Areas.IconCrop()
	local zoom = tonumber((ns.profile or {}).iconZoom) or ICON_ZOOM
	return math.min(math.max(zoom, 0), 90) / 200
end

-- If AddMessage stopped part-way (a hidden value it couldn't handle, design document beta check 19), the font string
-- it took is still out of the pool without being one of the engine's lines: give it back, or the pool runs dry.
local strays = {}
local function Reclaim(engine)
	local active = engine.activeFontStrings
	for line in engine.fontStringPool:EnumerateActive() do
		if not tContains(active, line) then strays[#strays + 1] = line end
	end
	for i = #strays, 1, -1 do
		engine.fontStringPool:Release(strays[i])
		strays[i] = nil
	end
end

-- line = { text, r, g, b, crit, sticky, staggered, icon, sizeOffset, font, outline } (Router.lua). crit: Blizzard shows it as a crit
-- (a sticky crit grows and shrinks); sticky: it stays in place. The table isn't kept.
-- Returns true when the line is showing.
function Areas.Add(areaID, line)
	local record = Areas.list[areaID] or Areas.list[Areas.Fallback()]
	local engine = record and record.engine
	if not engine or not engine.ctxSettings then return false end
	-- As Blizzard's frame skips text while it isn't visible (the interface hidden with Alt+Z), so nothing frozen shows
	-- up later.
	if not record.holder:IsVisible() then return false end
	local settings = engine.ctxSettings

	-- Blizzard drops new text when all 20 lines are in use; the oldest goes instead, so the newest always shows.
	local active = engine.activeFontStrings
	if #active >= MAX_LINES then engine:ReleaseFontString(active[1]) end

	local sticky, crit = line.sticky and true or false, line.crit and true or false
	local displayType = sticky and (crit and "crit" or "sticky") or nil
	local before = #active
	-- Blizzard's AddMessage stacks the new line from its own GetBottom/GetTop just after setting its text. A font string
	-- holding secret text measures as secret (design document 2.11), which Blizzard's own frame can compare (its code
	-- is untainted) but CTX's copy can't, so hidden text (damage, heals, power, aura names) would stop it part-way.
	-- Stacking only needs the line's height, which the words don't change: Blizzard gets a readable stand-in of the same
	-- font and size, and the real text goes in once the line is placed.
	local text = line.text
	local hidden = ns.IsSecret(text)
	-- The colour is passed as it is (the router always gives one): `or` would test it, and it isn't certain to be
	-- readable.
	-- When Busy "push" (Blizzard and Arc styles, moving lines): AddMessage sees no other line, so the new one starts at
	-- the start, and the lines before it are moved on below to make room (Styles.KeepApart, MSBT's way).
	local push = not sticky and Value(settings, "overflow") == "push" and engine.ctxStyle and engine.ctxStyle.stacks
	engine.ctxStacking = push and "none" or sticky
	-- Stagger off: the area's lines don't move sideways at random (Blizzard's damage and misses do, by 10 either way).
	local staggered = Value(settings, "stagger") ~= false and line.staggered or nil
	local ok, err = pcall(engine.AddMessage, engine, hidden and STAND_IN or text, LineScroll, line.r, line.g, line.b,
		displayType, staggered)
	engine.ctxStacking = nil
	if not ok then
		Reclaim(engine)
		if not reportedAddError then
			reportedAddError = true
			ns.ReportError("Areas.Add", err)
		end
		return false
	end
	if #active <= before then return false end
	local fontString = active[#active]
	if hidden then fontString:SetText(text) end
	-- The colour's opacity (Blizzard's AddMessage sets the colour without one), from the player's settings. It scales
	-- every SetAlpha on the line (OpacitySetAlpha), so Blizzard's fade runs down from it rather than from full.
	local alpha = type(line.a) == "number" and line.a < 1 and line.a or nil
	fontString.ctxOpacity = alpha
	if alpha then fontString:SetAlpha(1) end

	-- A type's own font and outline (false for the area's). "game" is the game's combat text font, whatever the area
	-- uses; the next line to use this font string gets the area's again from InitializeFontString.
	if line.font or line.outline then
		local font = engine.ctxFont
		local path = font.path
		if line.font == "game" then
			path = nil
		elseif line.font and ns.Media and ns.Media.FontPath then
			path = ns.Media.FontPath(line.font)
		end
		-- A new font object starts at its own height; AddMessage had set Blizzard's (crits 30, the rest 25).
		Areas.SetFont(fontString, path, line.outline or font.outline, crit and CRIT_START_HEIGHT or MESSAGE_HEIGHT)
		ApplyShadow(engine, fontString)
	end

	local style = sticky and engine.ctxStickyStyle or engine.ctxStyle
	local ctx = fontString.ctx or {}
	fontString.ctx = ctx
	ctx.t, ctx.warped = 0, 0
	ctx.alpha = alpha
	ctx.sticky, ctx.crit = sticky, crit
	ctx.style = style.key
	ctx.scroll = style.scroll
	local duration = Value(settings, sticky and "stickyDuration" or "duration")
	ctx.duration = type(duration) == "number" and duration > 0 and duration or DEFAULTS.duration
	ctx.align = engine.ctxAlign
	-- The area's text size plus the type's offset (-4: four smaller; crit types start at +5, Blizzard's 30 against
	-- 25). In the engine's units, as its scale already gives the area's size.
	ctx.h = MESSAGE_HEIGHT
	local offset = tonumber(line.sizeOffset)
	if offset and offset ~= 0 then
		ctx.h = math.max(engine.ctxFontSize + offset, MIN_TEXT_SIZE) * MESSAGE_HEIGHT / engine.ctxFontSize
	end
	ctx.blizzardPop = sticky and crit and style.key == "blizzard"
	-- A font made at each size does Blizzard's grow and shrink in LineScroll, as Blizzard's would scale it.
	ctx.ownPop = ctx.blizzardPop and fontString.ctxSized or nil
	if ctx.ownPop then
		fontString.isCrit = nil
		Areas.SetHeight(fontString, CRIT_START_HEIGHT)
	elseif not ctx.blizzardPop then
		fontString.isCrit = nil
		Areas.SetHeight(fontString, ctx.h)
	end

	if style.place then style.place(engine, fontString) end
	if push then ns.Styles.KeepApart(engine, fontString) end
	if line.icon and Value(settings, "icons") ~= "off" then AddIcon(engine, fontString, line.icon, settings) end
	-- AddMessage gives crits Blizzard's StandardScroll; every line takes CTX's.
	fontString.scrollFunction = LineScroll
	return true
end

-- Adding, renaming and deleting areas ----------------------------------------------------------------------------------

local function Copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, v in pairs(value) do copy[key] = Copy(v) end
	return copy
end

-- The default area, which new areas start from.
local function Template()
	local area = ns.DEFAULT_AREAS and ns.DEFAULT_AREAS.main
	return type(area) == "table" and area or DEFAULTS
end

-- IDs are "area" .. n, never reused within a profile (types may still point at a deleted area's ID), so the last
-- number used is kept in the profile.
local function NextID(profile)
	local last = type(profile.lastAreaNumber) == "number" and profile.lastAreaNumber or 0
	for id in pairs(profile.areas) do
		local n = type(id) == "string" and tonumber(id:match("^area(%d+)$"))
		if n and n > last then last = n end
	end
	last = last + 1
	profile.lastAreaNumber = last
	return "area" .. last
end

function Areas.New(name)
	local profile = ns.profile
	if not profile then return nil end
	profile.areas = profile.areas or {}
	local id = NextID(profile)
	local settings = Copy(Template())
	settings.name = type(name) == "string" and name ~= "" and name or L.AREA_DEFAULT_NAME
	settings.positions = {}
	settings.default = Copy(NEW_AREA_POSITION)
	profile.areas[id] = settings
	ns.Fire("AREAS_CHANGED", id)
	return id
end

-- Refuses to delete the last area (returns false).
function Areas.Delete(id)
	local areas = ns.profile and ns.profile.areas
	if not areas or areas[id] == nil then return false end
	local n = 0
	for _ in pairs(areas) do n = n + 1 end
	if n <= 1 then return false end
	areas[id] = nil
	ns.Fire("AREAS_CHANGED", id)
	return true
end

function Areas.Rename(id, name)
	local settings = Areas.Settings(id)
	if not settings or type(name) ~= "string" or name == "" then return false end
	settings.name = name
	ns.Fire("AREAS_CHANGED", id)
	return true
end

-- After the area's settings changed: the AREAS_CHANGED listener below applies them.
function Areas.Changed(id)
	ns.Fire("AREAS_CHANGED", id)
end

-- Notifications ----------------------------------------------------------------------------------------------------------

ns.Listen("DB_READY", function() Areas.Rebuild() end)
ns.Listen("AREAS_CHANGED", function(id) Areas.Rebuild(id) end)

ns.Listen("BLIZZARD_READY", function()
	for _, record in pairs(Areas.list) do Apply(record) end
	Areas.UpdateVisibility()
end)

ns.Listen("EDIT_MODE", function(on)
	editing = on and true or false
	Areas.UpdateVisibility()
end)

ns.Listen("EDIT_MODE_AREAS", function(shown)
	hiddenInEditMode = not shown
	Areas.UpdateVisibility()
end)

ns.Listen("SETTINGS_CHANGED", function()
	for _, record in pairs(Areas.list) do
		local engine = record.engine
		if engine then
			UpdateFont(engine)
			-- Another font can have another line height (MeasureDrop).
			local drop = engine.ctxDrop
			MeasureDrop(engine)
			if engine.ctxDrop ~= drop and engine.ctxSettings then engine:UpdateDisplayedMessages() end
		end
	end
	Areas.UpdateVisibility()
end)

ns.Listen("GAME_SETTING_CHANGED", function(cvar)
	if cvar == SCT_SETTING then
		Areas.UpdateVisibility()
	end
end)

-- The UI scale moves holders on the screen without changing WorldFrame's size, which is all Blizzard's OnUpdate
-- watches.
ns.On("UI_SCALE_CHANGED", RelayoutAll)
ns.On("DISPLAY_SIZE_CHANGED", RelayoutAll)
