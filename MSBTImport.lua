local addonName, ns = ...
local L = ns.L

-- Mik's Scrolling Battle Text's profiles as new CTX profiles (design document 4.2), from MSBT's saved settings file
-- pasted in: the MSBT preset, with what the player changed in MSBT on top.
--   ns.MSBTImport.Parse(text)        the pasted file's profiles ({ [name] = profile }), or nil
--   ns.MSBTImport.Names(profiles)    their names, sorted
--   ns.MSBTImport.Convert(p)         one MSBT profile as CTX profile data
--   ns.MSBTImport.ImportAll(profiles)  each as a new profile: the names made, and the one to switch to

ns.MSBTImport = {}
local Import = ns.MSBTImport

local NAME_LETTERS = 32 -- as Options.lua's
local MSBT_DEFAULT = "Default"

-- Reading the pasted file ------------------------------------------------------------------------------------------
-- MikScrollingBattleText.lua from WTF\Account\<account>\SavedVariables: assignments of plain tables, as the game
-- writes saved variables. It's read here as data, never run, so pasted text can't do anything.

local MAX_DEPTH = 32
local ESCAPES = {
	n = "\n", t = "\t", r = "\r", a = "\a", b = "\b", f = "\f", v = "\v",
	["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n",
}

local function Read(text)
	local pos, length = 1, #text

	local function Skip()
		while true do
			local _, last = text:find("^%s+", pos)
			if last then pos = last + 1 end
			if text:sub(pos, pos + 1) ~= "--" then return end
			local level = text:match("^%-%-%[(=*)%[", pos)
			local index = text:match("^%-%-[ \t]*%[%d+%]", pos)
			if level then
				local close = text:find("]" .. level .. "]", pos, true)
				pos = close and close + #level + 2 or length + 1
			elseif index then
				-- The game's "-- [1]" after a list entry, also when the paste lost its line breaks.
				pos = pos + #index
			else
				local lineEnd = text:find("\n", pos, true)
				pos = lineEnd and lineEnd + 1 or length + 1
			end
		end
	end

	local function String(quote)
		pos = pos + 1
		local out = {}
		local plain = "^[^\\\n" .. quote .. "]+"
		while pos <= length do
			local c = text:sub(pos, pos)
			if c == quote then
				pos = pos + 1
				return table.concat(out)
			elseif c == "\\" then
				local digits = text:match("^%d%d?%d?", pos + 1)
				local escaped = ESCAPES[text:sub(pos + 1, pos + 1)]
				if digits and tonumber(digits) <= 255 then
					out[#out + 1] = string.char(tonumber(digits))
					pos = pos + 1 + #digits
				elseif escaped then
					out[#out + 1] = escaped
					pos = pos + 2
				else
					return nil
				end
			elseif c == "\n" then
				return nil
			else
				local _, last = text:find(plain, pos)
				out[#out + 1] = text:sub(pos, last)
				pos = last + 1
			end
		end
		return nil
	end

	local Value
	local function Table(depth)
		if depth > MAX_DEPTH then return nil end
		pos = pos + 1
		local t, count = {}, 0
		while true do
			Skip()
			local c = text:sub(pos, pos)
			if c == "}" then
				pos = pos + 1
				return t
			end
			local key, ok, value
			local name = text:match("^[%a_][%w_]*", pos)
			if c == "[" then
				pos = pos + 1
				ok, key = Value(depth + 1)
				Skip()
				if not ok or key == nil or text:sub(pos, pos) ~= "]" then return nil end
				pos = pos + 1
				Skip()
				if text:sub(pos, pos) ~= "=" then return nil end
				pos = pos + 1
				ok, value = Value(depth + 1)
			elseif name and text:match("^%s*=[^=]", pos + #name) then
				key = name
				pos = text:find("=", pos + #name, true) + 1
				ok, value = Value(depth + 1)
			else
				count = count + 1
				key = count
				ok, value = Value(depth + 1)
			end
			if not ok then return nil end
			t[key] = value
			Skip()
			c = text:sub(pos, pos)
			if c == "," or c == ";" then
				pos = pos + 1
			elseif c ~= "}" then
				return nil
			end
		end
	end

	function Value(depth)
		Skip()
		local c = text:sub(pos, pos)
		if c == "{" then
			local t = Table(depth)
			return t ~= nil, t
		elseif c == '"' or c == "'" then
			local s = String(c)
			return s ~= nil, s
		end
		local word = text:match("^%a+", pos)
		if word == "true" or word == "false" then
			pos = pos + #word
			return true, word == "true"
		elseif word == "nil" then
			pos = pos + 3
			return true, nil
		end
		local number = text:match("^%-?0[xX]%x+", pos) or text:match("^%-?%d*%.?%d+[eE][%+%-]?%d+", pos)
			or text:match("^%-?%d*%.?%d+", pos)
		if number and tonumber(number) then
			pos = pos + #number
			return true, tonumber(number)
		end
		return false
	end

	local values = {}
	while true do
		Skip()
		if pos > length then return values end
		local name = text:match("^[%a_][%w_]*", pos)
		local ok, value
		if name then
			pos = pos + #name
			Skip()
			if text:sub(pos, pos) ~= "=" then return nil end
			pos = pos + 1
			ok, value = Value(1)
			values[name] = value
		else
			-- Just the table, pasted on its own.
			ok, value = Value(1)
			values[#values + 1] = value
		end
		if not ok then return nil end
	end
end

function Import.Parse(text)
	if type(text) ~= "string" or text == "" then return nil end
	local ok, values = pcall(Read, text)
	if not ok or type(values) ~= "table" then return nil end
	local saved = values.MSBTProfiles_SavedVars or values[1]
	local profiles = type(saved) == "table" and saved.profiles
	if type(profiles) ~= "table" then return nil end
	local found = {}
	for name, profile in pairs(profiles) do
		if type(profile) == "table" then found[tostring(name)] = profile end
	end
	return next(found) ~= nil and found or nil
end

local function Raw(t, key)
	if type(t) ~= "table" then return nil end
	return rawget(t, key)
end

local function Pick(saved, field, default)
	local value = Raw(saved, field)
	if value == nil then return default end
	return value
end

local function Number(value, default)
	return type(value) == "number" and value or default
end

local function Copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, inner in pairs(value) do copy[key] = Copy(inner) end
	return copy
end

local function Usable(kind, value)
	if ns.Media and ns.Media.Has and ns.Media.Has(kind, value) then return value end
	return false
end

local function Round(value)
	return math.floor(value * 100 + 0.5) / 100
end

-- MSBT's defaults (its MSBTProfiles.lua master profile) -------------------------------------------------------------------

local GENERAL = {
	normalFontName = "MSBT Porky", normalOutlineIndex = 1, normalFontSize = 18, normalFontAlpha = 100,
	critFontName = "MSBT Porky", critOutlineIndex = 1, critFontSize = 26, critFontAlpha = 100,
	animationSpeed = 100, cooldownThreshold = 5,
}

local function General(profile, field)
	return Pick(profile, field, GENERAL[field])
end

-- The four built-in scroll areas, as the MSBT preset's areas.
local AREAS = {
	Incoming = { id = "incoming", offsetX = -140, offsetY = -160, animationStyle = "Parabola", direction = "Down",
		behavior = "CurvedLeft", stickyBehavior = "Jiggle", textAlignIndex = 3 },
	Outgoing = { id = "outgoing", offsetX = 100, offsetY = -160, animationStyle = "Parabola", direction = "Down",
		behavior = "CurvedRight", stickyBehavior = "Jiggle", textAlignIndex = 1, iconAlign = "Right" },
	Notification = { id = "notification", offsetX = -175, offsetY = 120, scrollHeight = 200, scrollWidth = 350 },
	Static = { id = "static", offsetX = -20, offsetY = -300, scrollHeight = 125, animationStyle = "Static",
		direction = "Down" },
}
local AREA_ORDER = { "Incoming", "Outgoing", "Notification", "Static" }

-- MSBT's animation timings (MSBTAnimationStyles.lua): 260 px per 3 s, Static 3.15 s, Pow 0.17 + 1.5 + 0.5 s.
local MOVE = 3 / 260
local STATIC_TIME = 3.15
local POW_IN, POW_HOLD, POW_OUT = 0.17, 1.5, 0.5

local STYLES = { Straight = "blizzard", Parabola = "parabola", Angled = "angled", Static = "static" }
local STICKY_STYLES = { Pow = "pow", Static = "static" }
local ALIGN = { "left", "center", "right" }
-- MSBT's outlines 4 to 6 are the same with MONOCHROME, which CTX doesn't have.
local OUTLINES = { "", "OUTLINE", "THICKOUTLINE", "", "OUTLINE", "THICKOUTLINE" }

-- The MSBT event or trigger each CTX type takes its settings from, with MSBT's defaults for it: area, colour, size
-- (nil: its area's normal or crit size), crit, always sticky, sound, off. `follows` types take another's settings
-- but not its text; `noText` keeps Blizzard's two-form wording (Presets.lua).
local SOURCES = {}
local function Source(typeKey, key, area, r, g, b, fields)
	local entry = { key = key, area = area, r = r, g = g, b = b }
	for field, value in pairs(fields or {}) do entry[field] = value end
	SOURCES[typeKey] = entry
	return entry
end

local INCOMING, NOTIFICATION, STATIC = "Incoming", "Notification", "Static"
Source("DAMAGE", "INCOMING_DAMAGE", INCOMING, 1, 0, 0)
Source("DAMAGE_CRIT", "INCOMING_DAMAGE_CRIT", INCOMING, 1, 0, 0, { crit = true })
Source("SPELL_DAMAGE", "INCOMING_SPELL_DAMAGE", INCOMING, 1, 0, 0)
Source("SPELL_DAMAGE_CRIT", "INCOMING_SPELL_DAMAGE_CRIT", INCOMING, 1, 0, 0, { crit = true })
Source("DAMAGE_SHIELD", "INCOMING_SPELL_DAMAGE_SHIELD", INCOMING, 1, 0, 0)
for _, prefix in ipairs({ "", "SPELL_" }) do
	for _, word in ipairs({ "MISS", "DODGE", "PARRY", "DEFLECT" }) do
		Source(prefix .. word, "INCOMING_" .. prefix .. word, INCOMING, 0, 0, 1)
	end
	Source(prefix .. "BLOCK", "INCOMING_" .. prefix .. "BLOCK", INCOMING, 0, 0, 1, { noText = true })
	Source(prefix .. "ABSORB", "INCOMING_" .. prefix .. "ABSORB", INCOMING, 1, 1, 0, { noText = true })
	Source(prefix .. "IMMUNE", "INCOMING_" .. prefix .. "IMMUNE", INCOMING, 1, 1, 0)
	-- MSBT has no evades taken; they go with the other misses.
	Source(prefix .. "EVADE", "INCOMING_" .. prefix .. "MISS", INCOMING, 0, 0, 1, { follows = true })
end
Source("SPELL_REFLECT", "INCOMING_SPELL_REFLECT", INCOMING, 0.5, 0, 0.5)
Source("SPELL_RESIST", "INCOMING_SPELL_RESIST", INCOMING, 0.5, 0, 0.5, { noText = true })
-- MSBT has melee reflects and resists only as spell ones.
Source("REFLECT", "INCOMING_SPELL_REFLECT", INCOMING, 0.5, 0, 0.5, { follows = true })
Source("RESIST", "INCOMING_SPELL_RESIST", INCOMING, 0.5, 0, 0.5, { follows = true })
Source("HEAL", "INCOMING_HEAL", INCOMING, 0, 1, 0)
Source("HEAL_CRIT", "INCOMING_HEAL_CRIT", INCOMING, 0, 1, 0, { crit = true, size = 22 })
Source("PERIODIC_HEAL", "INCOMING_HOT", INCOMING, 0, 1, 0)
Source("PERIODIC_HEAL_CRIT", "INCOMING_HOT_CRIT", INCOMING, 0, 1, 0, { crit = true })
Source("ENERGIZE", "NOTIFICATION_POWER_GAIN", NOTIFICATION, 1, 1, 0)
Source("SPELL_AURA_START", "NOTIFICATION_BUFF", NOTIFICATION, 0.698, 0.698, 0)
Source("SPELL_AURA_START_HARMFUL", "NOTIFICATION_DEBUFF", NOTIFICATION, 0, 0.5, 0.5)
Source("SPELL_AURA_END", "NOTIFICATION_BUFF_FADE", NOTIFICATION, 0.918, 0.918, 0)
Source("SPELL_AURA_END_HARMFUL", "NOTIFICATION_DEBUFF_FADE", NOTIFICATION, 0, 0.835, 0.835)
Source("ENTERING_COMBAT", "NOTIFICATION_COMBAT_ENTER", NOTIFICATION, 1, 1, 1)
Source("LEAVING_COMBAT", "NOTIFICATION_COMBAT_LEAVE", NOTIFICATION, 1, 1, 1)
Source("FACTION", "NOTIFICATION_REP_GAIN", NOTIFICATION, 0.5, 0.5, 0.698)
Source("HONOR_GAINED", "NOTIFICATION_HONOR_GAIN", NOTIFICATION, 0.5, 0.5, 0.698)
Source("COOLDOWN", "NOTIFICATION_COOLDOWN", STATIC, 1, 1, 1, { size = 22, sound = "MSBT Cooldown" })
Source("LOOT", "NOTIFICATION_LOOT", STATIC, 1, 1, 0)
Source("MONEY", "NOTIFICATION_MONEY", STATIC, 1, 1, 1)
Source("CURRENCY", "NOTIFICATION_CURRENCY", STATIC, 1, 1, 0)
Source("EXPERIENCE", "NOTIFICATION_EXPERIENCE_GAIN", NOTIFICATION, 0.756, 0.270, 0.823,
	{ size = 26, sticky = true, off = true })
Source("SKILL", "NOTIFICATION_SKILL_GAIN", NOTIFICATION, 0.333, 0.333, 1)
-- Low health and mana are triggers in MSBT.
Source("HEALTH_LOW", "MSBT_TRIGGER_LOW_HEALTH", NOTIFICATION, 1, 0.5, 0.5,
	{ trigger = true, size = 26, sticky = true, sound = "MSBT Low Health" })
Source("MANA_LOW", "MSBT_TRIGGER_LOW_MANA", NOTIFICATION, 0.5, 0.5, 1,
	{ trigger = true, size = 26, sticky = true, sound = "MSBT Low Mana" })

local TRIGGERS = {
	EXECUTE = "MSBT_TRIGGER_EXECUTE", OVERPOWER = "MSBT_TRIGGER_OVERPOWER", REVENGE = "MSBT_TRIGGER_REVENGE",
	HAMMER_OF_WRATH = "MSBT_TRIGGER_HAMMER_OF_WRATH", CLEARCASTING = "MSBT_TRIGGER_CLEARCASTING",
}

-- Converting ---------------------------------------------------------------------------------------------------------

-- MSBT's %sl is its spell's full name; its %e is the faction on reputation and the spell on cooldowns.
local function Template(message, typeKey)
	local text = message:gsub("%%sl", "%%s")
	if typeKey == "FACTION" or typeKey == "COOLDOWN" then text = text:gsub("%%e", "%%s") end
	local def = ns.TYPE and ns.TYPE[typeKey]
	if text == "" or (def and text == def.template) then return false end
	return text
end

-- MSBT saves a deleted built-in trigger as false.
local function TriggerSaved(profile, key)
	local saved = Raw(Raw(profile, "triggers"), key)
	if saved == false then return { deleted = true } end
	return type(saved) == "table" and saved or nil
end

local function AreaFrom(key, saved, profile, preset)
	local defaults = AREAS[key] or {}
	local function Get(field, base)
		local default = defaults[field]
		if default == nil then default = base end
		return Pick(saved, field, default)
	end
	local area = Copy(preset or ns.DEFAULT_AREAS.main)
	local width = Number(Get("scrollWidth"), 40)
	local height = Number(Get("scrollHeight"), 260)
	local fontSize = Number(Get("normalFontSize", General(profile, "normalFontSize")), 18)
	local speed = Number(Get("animationSpeed", General(profile, "animationSpeed")), 100) / 100
	if speed <= 0 then speed = 1 end

	if not preset then area.name = key end
	local name = Raw(saved, "name")
	if type(name) == "string" and name ~= "" then area.name = name end

	local msbtStyle = Get("animationStyle", "Straight")
	local style = STYLES[msbtStyle] or "blizzard"
	local direction, behavior = Get("direction", "Up"), Get("behavior")
	area.style = style
	if style == "angled" then
		area.direction = (direction == "Left" and "left") or (direction == "Right" and "right") or "alternate"
		area.behavior = behavior == "AngleDown" and "down" or "up"
	else
		area.direction = direction == "Down" and "down" or "up"
		area.behavior = style == "parabola" and (behavior == "CurvedRight" and "right" or "left") or false
	end
	local duration
	if msbtStyle == "Static" then
		duration = STATIC_TIME / speed
	elseif msbtStyle == "Angled" then
		-- The longest line: from the side to 85 % across, rising the area's height less a line.
		local rise = height - fontSize - 8
		if rise < 0 then rise = height end
		local across = width * 0.85
		duration = (math.sqrt(across * across + rise * rise) * MOVE + 1) / speed + 0.5
	else
		duration = height * MOVE / speed
	end
	area.duration = Round(duration)

	local stickyStyle = STICKY_STYLES[Get("stickyAnimationStyle", "Pow")] or "pow"
	area.stickyStyle = stickyStyle
	area.stickyBehavior = stickyStyle == "pow" and (Get("stickyBehavior") == "Jiggle" and "jiggle" or "normal") or false
	area.stickyDuration = Round(stickyStyle == "static" and STATIC_TIME / speed or POW_IN + POW_HOLD / speed + POW_OUT)

	area.width, area.height, area.fontSize = width, height, fontSize
	area.align = ALIGN[Number(Get("textAlignIndex"), 2)] or "center"
	local noIcons = Get("skillIconsDisabled") or General(profile, "skillIconsDisabled")
	area.icons = noIcons and "off" or (Get("iconAlign") == "Right" and "right" or "left")
	-- MSBT places an area by its bottom-left corner from the screen's centre; CTX by its centre.
	local x, y = Number(Get("offsetX"), 0), Number(Get("offsetY"), 0)
	area.default = { point = "CENTER", x = Round(x + width / 2), y = Round(y + height / 2) }
	area.positions = {}
	return area, Get
end

-- The CTX areas and what each MSBT scroll area became: zones[msbtKey] = { id, get, size } (nil for one that's off).
local function Areas(profile, data)
	local saved = Raw(profile, "scrollAreas")
	if type(saved) ~= "table" then saved = {} end
	local presetAreas = ns.PRESET and ns.PRESET.msbt and ns.PRESET.msbt.areas or {}
	local keys = {}
	for _, key in ipairs(AREA_ORDER) do keys[#keys + 1] = key end
	local custom = {}
	for key, settings in pairs(saved) do
		if not AREAS[key] and type(settings) == "table" then custom[#custom + 1] = tostring(key) end
	end
	table.sort(custom)
	for _, key in ipairs(custom) do keys[#keys + 1] = key end

	local zones, number = {}, 0
	data.areas = {}
	for _, key in ipairs(keys) do
		local settings = Raw(saved, key)
		if not Raw(settings, "disabled") then
			local id = AREAS[key] and AREAS[key].id
			if not id then
				number = number + 1
				id = "area" .. number
			end
			local area, get = AreaFrom(key, settings, profile, AREAS[key] and presetAreas[id])
			data.areas[id] = area
			zones[key] = { id = id, get = get, size = area.fontSize }
		end
	end
	if number > 0 then data.lastAreaNumber = number end
	return zones
end

local function TypeFrom(typeKey, source, saved, profile, zones)
	local entry = Copy(ns.PRESET.msbt.types[typeKey] or {})
	local zone = zones[Pick(saved, "scrollArea", source.area)]
	local off = Pick(saved, "disabled", source.off or false) or Raw(saved, "deleted")
	entry.enabled = not off and zone ~= nil
	if not zone then return entry end
	entry.area = zone.id

	local crit = source.crit
	local kind = crit and "crit" or "normal"
	local function Look(field, eventField)
		local value = Raw(saved, eventField)
		if value ~= nil then return value end
		return zone.get(kind .. field, General(profile, kind .. field))
	end
	local size = Number(Pick(saved, "fontSize", source.size), nil) or Number(Look("FontSize", "fontSize"), zone.size)
	entry.sizeOffset = size - zone.size
	local font = Look("FontName", "fontName")
	entry.font = font ~= General(profile, "normalFontName") and Usable("font", font) or false
	local outline = Look("OutlineIndex", "outlineIndex")
	entry.outline = outline ~= General(profile, "normalOutlineIndex") and OUTLINES[outline] or false
	local alpha = Number(Look("FontAlpha", "fontAlpha"), 100)
	entry.color = {
		r = Number(Pick(saved, "colorR", source.r), 1),
		g = Number(Pick(saved, "colorG", source.g), 1),
		b = Number(Pick(saved, "colorB", source.b), 1),
		a = alpha < 100 and math.max(alpha, 0) / 100 or nil,
	}

	if Pick(saved, "alwaysSticky", source.sticky or false) then
		entry.sticky = "always"
	elseif crit and General(profile, "stickyCritsDisabled") then
		entry.sticky = "never"
	else
		entry.sticky = "blizzard"
	end
	local sound = Pick(saved, "soundFile", source.sound)
	entry.sound = type(sound) == "string" and sound ~= "" and Usable("sound", sound) or false

	local message = Raw(saved, "message")
	if not (source.follows or source.noText) and type(message) == "string" then
		entry.template = Template(message, typeKey)
	end
	return entry
end

local function TriggerFrom(saved, zones)
	local entry = {}
	if Raw(saved, "deleted") or Raw(saved, "disabled") then entry.enabled = false end
	local message = Raw(saved, "message")
	if type(message) == "string" and message ~= "" then entry.message = message:gsub("%%sl", "%%s") end
	local r, g, b = Raw(saved, "colorR"), Raw(saved, "colorG"), Raw(saved, "colorB")
	if r ~= nil or g ~= nil or b ~= nil then
		entry.color = { r = Number(r, 1), g = Number(g, 1), b = Number(b, 0) }
	end
	local sound = Raw(saved, "soundFile")
	if type(sound) == "string" and sound ~= "" then entry.sound = Usable("sound", sound) end
	local area = Raw(saved, "scrollArea")
	if area ~= nil then entry.area = zones[area] and zones[area].id or false end
	if Raw(saved, "alwaysSticky") == false then entry.sticky = false end
	return entry
end

function Import.Convert(profile)
	if type(profile) ~= "table" then profile = {} end
	local data = {}
	local zones = Areas(profile, data)

	local events = Raw(profile, "events")
	data.types = {}
	for typeKey, fields in pairs(ns.PRESET.msbt.types) do data.types[typeKey] = Copy(fields) end
	for typeKey, source in pairs(SOURCES) do
		if ns.TYPE[typeKey] then
			local saved
			if source.trigger then
				saved = TriggerSaved(profile, source.key)
			else
				saved = Raw(events, source.key)
				if type(saved) ~= "table" then saved = nil end
			end
			data.types[typeKey] = TypeFrom(typeKey, source, saved, profile, zones)
		end
	end
	for _, entry in pairs(data.types) do
		if entry.sound then entry.sound = Usable("sound", entry.sound) end
	end

	data.triggers = { builtin = {}, custom = {} }
	for key, msbtKey in pairs(TRIGGERS) do
		local saved = TriggerSaved(profile, msbtKey)
		if saved and ns.BUILTIN_TRIGGER[key] then data.triggers.builtin[key] = TriggerFrom(saved, zones) end
	end

	data.font = Usable("font", General(profile, "normalFontName"))
	data.outline = OUTLINES[Number(General(profile, "normalOutlineIndex"), 1)] or ""
	data.shadow = not General(profile, "textShadowingDisabled")
	data.numbers = General(profile, "shortenNumbers") and "short" or General(profile, "groupNumbers") and "grouped" or "full"
	data.sounds = not General(profile, "soundsDisabled")
	data.cooldowns = { minLength = math.min(math.max(Number(General(profile, "cooldownThreshold"), 5), 0), 60) }
	return data
end

-- Names: "MSBT Import" for MSBT's default profile, "MSBT Import (Name)" for the others, shortened to fit and with a
-- number added when taken.

local function Shorten(name, letters)
	while strlenutf8(name) > letters do
		local shorter = name:gsub("[^\128-\191][\128-\191]*$", "")
		if shorter == name then shorter = name:sub(1, -2) end
		name = shorter
	end
	return name
end

local function NewName(source, taken)
	local name = L.PROFILE_MSBT_NAME
	if source ~= MSBT_DEFAULT and not source:find("^%s*$") then
		local room = NAME_LETTERS - strlenutf8(L.PROFILE_MSBT_NAME_OF:format(""))
		name = L.PROFILE_MSBT_NAME_OF:format(Shorten(source, math.max(room, 1)))
	end
	name = Shorten(name, NAME_LETTERS)
	local unused, number = name, 1
	while taken[unused] do
		number = number + 1
		local suffix = " " .. number
		unused = Shorten(name, NAME_LETTERS - #suffix) .. suffix
	end
	return unused
end

-- Importing ----------------------------------------------------------------------------------------------------------

function Import.Names(profiles)
	local names = {}
	for name in pairs(profiles or {}) do names[#names + 1] = name end
	table.sort(names)
	return names
end

-- New profiles are written straight into AceDB's saved profiles; AceDB fills in the defaults when one is first used.
-- The one to switch to is MSBT's Default's (each character's own choice is in a file of its own), else the first.
function Import.ImportAll(profiles)
	if not ns.db or type(profiles) ~= "table" then return {} end
	local taken = {}
	for _, name in ipairs((ns.db:GetProfiles({}))) do taken[name] = true end
	local made, renamed = {}, {}
	for _, source in ipairs(Import.Names(profiles)) do
		local name = NewName(source, taken)
		taken[name] = true
		ns.db.profiles[name] = Import.Convert(profiles[source])
		made[#made + 1] = name
		renamed[source] = name
	end
	table.sort(made)
	return made, renamed[MSBT_DEFAULT] or made[1]
end
