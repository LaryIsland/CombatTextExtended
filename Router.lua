local addonName, ns = ...

-- From a message to an area (design document 3, 4.5, 4.6, 4.8). Blizzard's own messages arrive through Blizzard.lua's
-- hooks with the message type and the event's values; CTX's own text (cooldowns, triggers, loot) arrives with
-- readable values. Either way the event type's settings decide whether it shows, its text (Blizzard's message, or the
-- player's template built from the values), colour, sticky, sound, text size and area.
--
-- Blizzard decides what shows: a message that reaches here was already shown by Blizzard's own code (the game's
-- switches applied), so only CTX's per-type on/off is checked. Blizzard's messages and values may be hidden: they're
-- only handed on, never tested (Format.lua joins them).

local Router = {}
ns.Router = Router

local SCT_SETTING = "enableFloatingCombatText"
local REDUCTION_SETTING = "floatingCombatTextDamageReduction_v2"
-- The question mark icon, for samples of CTX's own types (which show the spell's or item's icon for real).
local SAMPLE_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local EMPTY = {}
-- The one line table handed to Areas.Add, which doesn't keep it, so nothing is built per line.
local line = {}

-- CTX is on, Blizzard_CombatText is loaded (its code runs every area) and the game's "Scrolling Combat Text for Self"
-- is on (without it, Blizzard's frame gets no events and so CTX gets no messages).
function Router.Active()
	local profile = ns.profile
	if not profile or profile.enabled == false then return false end
	if not (ns.Areas and ns.Areas.Ready and ns.Areas.Ready()) then return false end
	return ns.GameSetting(SCT_SETTING)
end
local Active = Router.Active

function Router.TypeSettings(key)
	local types = ns.profile and ns.profile.types
	return types and key ~= nil and types[key] or nil
end
local TypeSettings = Router.TypeSettings

-- Picking --------------------------------------------------------------------------------------------------------------

local function Enabled(def, settings)
	if settings then return settings.enabled ~= false end
	return def.defaultEnabled ~= false
end

-- The game's own switch for the type is on (a type behind several is on when any of them is). Only for samples:
-- Blizzard's messages have already passed it.
local function GameShows(def)
	if def.gameSettings then
		for _, cvar in ipairs(def.gameSettings) do
			if ns.GameSetting(cvar) then return true end
		end
		return false
	end
	if def.gameSetting then return ns.GameSetting(def.gameSetting) end
	return true
end

-- The area, or the first area when there's none or it was deleted.
local function AreaOf(id)
	local list = ns.Areas and ns.Areas.list
	if id and list and list[id] then return id end
	return ns.Areas and ns.Areas.Fallback and ns.Areas.Fallback()
end

-- Colours are { r, g, b } or { r = , g = , b = } (triggers).
local function Unpack(color)
	if type(color) ~= "table" then return nil end
	local r, g, b = color.r or color[1], color.g or color[2], color.b or color[3]
	if type(r) == "number" and type(g) == "number" and type(b) == "number" then return r, g, b end
	return nil
end

-- A colour's opacity (the colour picker's), 1 when it has none.
local function Alpha(color)
	local a = type(color) == "table" and color.a
	if type(a) == "number" and a >= 0 and a < 1 then return a end
	return 1
end
Router.Alpha = Alpha

-- A CTX type copying a chat type's colour uses the player's own chat colour for it.
local function DefaultColor(def)
	local info = def.chatType and ChatTypeInfo and ChatTypeInfo[def.chatType]
	local r, g, b = Unpack(info)
	if r then return r, g, b end
	r, g, b = Unpack(def.color)
	if r then return r, g, b end
	return 1, 1, 1
end

-- sticky: "blizzard" (as Blizzard marks the line), "always" or "never". Returns sticky, crit: crit lines (Blizzard's
-- "crit") get the area's crit size, and grow and shrink when they stay.
local function Sticky(setting, displayType)
	local crit = displayType == "crit"
	if setting == "always" then return true, crit end
	if setting == "never" then return false, crit end
	return crit or displayType == "sticky", crit
end

-- The Remove < > option (design document 4.2): the game's and CTX's own wording without the < > around names
-- ("<Shield Wall>" shows as "Shield Wall"). The player's own text keeps whatever they wrote.
local function NoBrackets()
	return ns.profile and ns.profile.noBrackets == true
end

-- A default wording as the option says: without its < > when the option is on. Hidden text is left as it is.
function Router.Wording(text)
	if not NoBrackets() or type(text) ~= "string" or ns.IsSecret(text) or not text:find("[<>]") then return text end
	return (text:gsub("[<>]", ""))
end
local Wording = Router.Wording

-- The template a type starts from with these values: the partial block, absorb or resist form when there's an amount
-- reduced (samples and CTX's own text; Blizzard's messages say which form they are themselves).
local function DefaultTemplate(def, values)
	if def.partialTemplate and values and values.r ~= nil then return Wording(def.partialTemplate) end
	return Wording(def.template)
end

-- style: the type's settings, for its text size offset, font and outline (false: the area's), and its colour's
-- opacity. alpha: an opacity of its own (a trigger's colour), instead of the type's.
local function Send(areaID, text, r, g, b, sticky, crit, staggered, icon, style, alpha)
	if areaID == nil or not (ns.Areas and ns.Areas.Add) then return false end
	line.text, line.r, line.g, line.b = text, r, g, b
	line.a = alpha or Alpha(style.color)
	line.sticky, line.crit, line.staggered = sticky, crit, staggered
	line.icon = icon
	line.sizeOffset, line.font, line.outline = style.sizeOffset or nil, style.font or nil, style.outline or nil
	local shown = ns.Areas.Add(areaID, line)
	line.text = nil
	return shown
end

-- A sound plays at most once in SOUND_GAP seconds: a burst of heal ticks or hits with the same sound plays it once,
-- not stacked. Samples (force) always play.
local SOUND_GAP = 0.2
local lastPlayed = {}
local function PlaySound(value, force)
	if not (value and ns.Media and ns.Media.Play) then return end
	local now = GetTime()
	if not force and lastPlayed[value] and now - lastPlayed[value] < SOUND_GAP then return end
	lastPlayed[value] = now
	ns.Media.Play(value)
end

-- Blizzard's messages --------------------------------------------------------------------------------------------------

-- Whether a player's template can be built from these values: false when it uses a code the type requires (its
-- `requires`, for example the power's name) and the event didn't give it, so Blizzard's own message shows instead of
-- a half-filled one. The template is the player's own text, so it can be searched.
local function Fills(def, template, values)
	for _, code in ipairs(def.requires or EMPTY) do
		if template:find("%" .. code, 1, true) and (values == nil or values[code] == nil) then return false end
	end
	return true
end

-- Blizzard words a block, absorb or resist two ways: the full one ("Block") and the partial one, with the damage taken
-- ("-120 (40 blocked)"). A type has one template, so the player's is used for the form it's written for: with %r (the
-- amount blocked) for the partial one, without for the full one. The other form, and an absorb that can't be told
-- apart while its amount is secret, keep Blizzard's message.
local function FitsForm(def, feed, template, data, arg3, arg4)
	if not (feed.partial and def.gameSetting == REDUCTION_SETTING) then return true end
	local partial = feed.partial(data, arg3, arg4)
	if partial == nil then return false end
	return (template:find("%r", 1, true) ~= nil) == partial
end

-- When the game's Damage Reduction switch is off, Blizzard shows a partial block, absorb or resist as damage
-- (CombatText.lua:123-134), so it counts as damage here. Its message is a crit when the hit was (displayType).
local function ShownAsDamage(feedType, displayType)
	local info = CombatTextTypeInfo and CombatTextTypeInfo[feedType]
	if not info or info.show or info.cvar ~= REDUCTION_SETTING then return nil end
	local crit = displayType == "crit"
	if feedType:sub(1, 5) == "SPELL" then
		return crit and "SPELL_DAMAGE_CRIT" or "SPELL_DAMAGE"
	end
	return crit and "DAMAGE_CRIT" or "DAMAGE"
end

-- From Blizzard.lua's hooks: Blizzard's message type, its finished message, colour, display type ("crit", "sticky" or
-- nil) and stagger, and C_CombatText.GetCurrentEventInfo's values for that event (nil for the types Blizzard's frame
-- makes itself).
function Router.FromBlizzard(feedType, message, r, g, b, displayType, isStaggered, data, arg3, arg4)
	if type(feedType) ~= "string" or not Active() then return end
	if ns.IsSecret(displayType) then displayType = nil end
	local feed = ns.FEED and ns.FEED[feedType]
	local typeKey = ShownAsDamage(feedType, displayType) or (feed and feed.type)
	local def = typeKey and ns.TYPE and ns.TYPE[typeKey]
	if not def then return end
	local settings = TypeSettings(typeKey)
	if not Enabled(def, settings) then return end
	settings = settings or EMPTY

	-- A trigger for the same spell shows instead of Blizzard's Spell Alert (4.9).
	if typeKey == "SPELL_ACTIVE" and ns.Triggers and ns.Triggers.SuppressAlert and ns.Triggers.SuppressAlert(data) then
		return
	end

	-- The player's template, built from the event's values; Blizzard's message if there's none or it can't be built.
	local text = message
	local own = false
	local template = settings.template
	if type(template) == "string" and template ~= "" and feed and feed.values and not feed.wording
			and FitsForm(def, feed, template, data, arg3, arg4) then
		local values = feed.values(data, arg3, arg4)
		if Fills(def, template, values) then
			local built = ns.Format.Build(template, values)
			if ns.Present(built) then text, own = built, true end
		end
	end
	-- Blizzard's message without its < > (Remove < >): taken out when the message is readable, or else the message is
	-- built again from the type's own wording, which is Blizzard's (an aura's or spell's name keeps it hidden).
	if not own and NoBrackets() then
		if feed and feed.wording and feed.values then
			-- Blizzard's wording without its < >, written again from readable values (combo points: their total).
			local values = feed.values(data, arg3, arg4)
			if values.a ~= nil then
				local built = ns.Format.Build(feed.wording, values)
				if ns.Present(built) then text = built end
			end
		elseif not ns.IsSecret(message) then
			text = Wording(message)
		elseif feed and feed.values and type(def.template) == "string" and Wording(def.template) ~= def.template then
			-- Only when every value the wording needs is there (a combo point total can't be worked out from hidden
			-- values); otherwise Blizzard's message stays as it is.
			local values = feed.values(data, arg3, arg4)
			if Fills(def, def.template, values) then
				local built = ns.Format.Build(Wording(def.template), values)
				if ns.Present(built) then text = built end
			end
		end
	end

	local cr, cg, cb = Unpack(settings.color)
	if cr then r, g, b = cr, cg, cb end
	if not (ns.Present(r) and ns.Present(g) and ns.Present(b)) then r, g, b = DefaultColor(def) end

	local sticky, crit = Sticky(settings.sticky, displayType)
	if Send(AreaOf(settings.area), text, r, g, b, sticky, crit, isStaggered, nil, settings) then
		PlaySound(settings.sound)
	end
end

-- CTX's own text -------------------------------------------------------------------------------------------------------

-- typeKey: one of CTX's own types, or TRIGGER. values: readable. extra (all optional) = { icon, color, sound, area,
-- sticky, message }; triggers pass their own settings, and their message instead of the type's template.
function Router.Show(typeKey, values, extra)
	if not Active() then return false end
	local def = ns.TYPE and ns.TYPE[typeKey]
	if not def then return false end
	local settings = TypeSettings(typeKey)
	if settings and settings.enabled == false then return false end
	settings = settings or EMPTY
	extra = extra or EMPTY

	local template = extra.message
	if type(template) ~= "string" or template == "" then
		template = type(settings.template) == "string" and settings.template ~= "" and settings.template
			or DefaultTemplate(def, values)
	end
	local text = ns.Format.Build(template, values)
	if text == nil then return false end

	local r, g, b = Unpack(extra.color)
	if not r then r, g, b = Unpack(settings.color) end
	if not r then r, g, b = DefaultColor(def) end

	local sticky
	if extra.sticky ~= nil then
		sticky = extra.sticky and true or false
	else
		sticky = Sticky(settings.sticky, def.sticky and "crit" or nil)
	end
	local crit = sticky and def.sticky == true

	-- Triggers without an area of their own go where Spell Alerts go (they stand in for them).
	local area = extra.area or settings.area
	if not extra.area and def.internal then area = (TypeSettings("SPELL_ACTIVE") or EMPTY).area end

	if not Send(AreaOf(area), text, r, g, b, sticky, crit, nil, extra.icon, settings,
			extra.color and Alpha(extra.color) or nil) then
		return false
	end
	if extra.sound ~= nil then
		PlaySound(extra.sound)
	else
		PlaySound(settings.sound)
	end
	return true
end

-- Samples and previews -------------------------------------------------------------------------------------------------

-- A type's text with its sample values: the player's template, or the type's own. Blizzard's messages group digits,
-- so its unchanged templates do too; CTX's own types and changed templates follow the profile's number format.
-- A type's sample values, and the colour the game would give them: the player's own where the type can work it out
-- (power gains show the player's power, in its colour), else the catalogue's.
-- preview: for the Event Types popup, which wants the same sample each time it redraws (not a new spell each time).
local function SampleValues(def, preview)
	if def.liveSample then
		local values, color, icon = def.liveSample(preview)
		if values then return values, color, icon end
	end
	return def.sample or EMPTY, nil, nil
end

local function SampleText(def, settings, preview)
	local values, color, icon = SampleValues(def, preview)
	local template = settings and settings.template
	local numbers
	if type(template) ~= "string" or template == "" then
		template = DefaultTemplate(def, values)
		if not def.own then numbers = "grouped" end
	end
	return ns.Format.Build(template, values, numbers), color, icon
end

-- The text a type would show (the Event Types popup's preview). Always readable.
function Router.PreviewText(typeKey)
	local def = ns.TYPE and ns.TYPE[typeKey]
	if not def then return "" end
	return (SampleText(def, TypeSettings(typeKey), true)) or ""
end

-- The colour a type's preview shows in: the player's, Blizzard's for its sample (a power gain's power colour), or the
-- type's own.
function Router.PreviewColor(typeKey)
	local def = ns.TYPE and ns.TYPE[typeKey]
	if not def then return 1, 1, 1 end
	local own = (TypeSettings(typeKey) or EMPTY).color
	local r, g, b = Unpack(own)
	if r then return r, g, b, Alpha(own) end
	local _, color = SampleValues(def, true)
	if color and color.r then return color.r, color.g, color.b, 1 end
	local dr, dg, db = DefaultColor(def)
	return dr, dg, db, 1
end

-- Shows the type in its area with its sample values, as it would really show. Edit Mode's samples are silent; test
-- mode's (live) play the type's sound too.
function Router.Sample(typeKey, live)
	if not Active() then return false end
	local def = ns.TYPE and ns.TYPE[typeKey]
	if not def then return false end
	local settings = TypeSettings(typeKey)
	if not Enabled(def, settings) then return false end
	settings = settings or EMPTY
	local text, sampleColor, sampleIcon = SampleText(def, settings)
	if text == nil then return false end

	local r, g, b = Unpack(settings.color)
	if not r and sampleColor and sampleColor.r then r, g, b = sampleColor.r, sampleColor.g, sampleColor.b end
	if not r then r, g, b = DefaultColor(def) end
	local sticky, crit = Sticky(settings.sticky, def.sticky and "crit" or nil)
	local info = CombatTextTypeInfo and CombatTextTypeInfo[typeKey]
	local staggered = info and info.isStaggered or nil
	local area = def.internal and (TypeSettings("SPELL_ACTIVE") or EMPTY).area or settings.area
	local icon = def.own and (sampleIcon or SAMPLE_ICON) or nil
	if not Send(AreaOf(area), text, r, g, b, sticky, crit, staggered, icon, settings) then return false end
	if live then PlaySound(settings.sound) end
	return true
end

-- Shows one of the types that go to this area, picked at random from those that would show (CTX's switch and the
-- game's both on). An area nothing goes to yet shows its own name in white, so it can still be placed and styled.
local candidates = {}
function Router.SampleArea(areaID)
	if areaID == nil or not Active() then return false end
	local n = 0
	for _, def in ipairs(ns.TYPES or EMPTY) do
		local settings = TypeSettings(def.key)
		if Enabled(def, settings) and GameShows(def) and AreaOf(settings and settings.area) == areaID then
			n = n + 1
			candidates[n] = def.key
		end
	end
	local picked = n > 0 and candidates[math.random(n)] or nil
	for i = 1, n do candidates[i] = nil end
	if not picked then
		local settings = ns.Areas and ns.Areas.Settings and ns.Areas.Settings(areaID)
		local name = settings and settings.name
		if type(name) ~= "string" or name == "" then return false end
		return Send(areaID, name, 1, 1, 1, false, false, nil, nil, EMPTY)
	end
	return Router.Sample(picked)
end

-- Bursts: after an area's sticky style or icons setting changes in Edit Mode, BURST_COUNT lines show it, one every
-- BURST_GAP seconds. A newer burst stops an older one.
local BURST_COUNT, BURST_GAP = 5, 0.25
local burstRun = 0

-- A type's sample as it would really show: text, colour and the type's own settings (for its size, font, outline).
local function SampleLine(key)
	local def = ns.TYPE and ns.TYPE[key]
	if not def then return nil end
	local settings = TypeSettings(key) or EMPTY
	local text, sampleColor = SampleText(def, settings)
	if text == nil then return nil end
	local r, g, b = Unpack(settings.color)
	if not r and sampleColor and sampleColor.r then r, g, b = sampleColor.r, sampleColor.g, sampleColor.b end
	if not r then r, g, b = DefaultColor(def) end
	return text, r, g, b, settings
end

-- The sticky type the area shows (a crit type that goes there), or damage crits.
local function StickyKey(areaID)
	for _, def in ipairs(ns.TYPES or EMPTY) do
		local settings = TypeSettings(def.key)
		if def.sticky == true and not def.internal and Enabled(def, settings)
			and AreaOf(settings and settings.area) == areaID then
			return def.key
		end
	end
	return "DAMAGE_CRIT"
end

-- kind: "sticky" (lines that stay in place, as crits) or "icons" (cooldown lines with the player's own spell icons).
function Router.SampleBurst(areaID, kind)
	if areaID == nil or not Active() then return end
	burstRun = burstRun + 1
	local run = burstRun
	local stickyKey = kind == "sticky" and StickyKey(areaID)
	for i = 1, BURST_COUNT do
		C_Timer.After((i - 1) * BURST_GAP, function()
			if run ~= burstRun or not Active() then return end
			if kind == "sticky" then
				local text, r, g, b, settings = SampleLine(stickyKey)
				if text then Send(areaID, text, r, g, b, true, true, nil, nil, settings) end
				return
			end
			-- One of the player's tracked spells each time, in the cooldown type's text and colour.
			local text, r, g, b, settings = SampleLine("COOLDOWN")
			local name, icon
			if ns.Cooldowns and ns.Cooldowns.SampleSpell then name, icon = ns.Cooldowns.SampleSpell() end
			if name and settings then
				local template = type(settings.template) == "string" and settings.template ~= "" and settings.template
					or DefaultTemplate(ns.TYPE.COOLDOWN, EMPTY)
				text = ns.Format.Build(template, { s = name }) or text
			end
			if text then Send(areaID, text, r, g, b, false, false, nil, icon or SAMPLE_ICON, settings) end
		end)
	end
end
