local addonName, ns = ...
local L = ns.L

-- The saved settings' defaults, and the presets players can start from (design document 1.1, 4.1).
--   ns.PROFILE_DEFAULTS            AceDB profile defaults: everything but areas and the player's own triggers' entries
--   ns.DEFAULT_AREAS               the areas a new or reset profile gets
--   ns.PRESETS / ns.PRESET[key]    ordered { key, label, description, areas, types, general, cooldowns? }
--   ns.ApplyPresetAreas(profile, key)  writes a preset's areas (the defaults without one) into a profile, replacing any
--   ns.ApplyPreset(key)            sets up the current profile's areas, event types and style as a preset
--
-- The defaults are what CTX looks like out of the box: one area where Blizzard's text is, with Blizzard's look, so
-- installing CTX changes nothing until the player moves or changes something. The MSBT preset is MSBT's default
-- profile (MSBT_Forever's MSBTProfiles.lua) on CTX's types; LaryIsland's Config is the author's own MSBT profile.

-- Profile defaults ---------------------------------------------------------------------------------------------------
-- Every type and built-in trigger has an entry, so code can read profile.types[key] without checking. false means
-- "as Blizzard has it" (colour, template), "the area's" (font, outline) or "none" (sound). A type's font is
-- "game" for the game's combat text font, or a LibSharedMedia name; its outline "", "OUTLINE" or "THICKOUTLINE".

-- A type's text size is an offset from its area's. Crit types (and Spell Alerts, which Blizzard shows as crits) start
-- bigger, as Blizzard's crits settle at 30 against its 25.
local CRIT_OFFSET = 5

local function TypeDefaults()
	local types = {}
	for _, def in ipairs(ns.TYPES) do
		types[def.key] = {
			enabled = def.defaultEnabled,
			area = "main",
			color = false,
			template = false,
			sound = false,
			sticky = "blizzard",
			sizeOffset = def.sticky == true and CRIT_OFFSET or 0,
			font = false,
			outline = false,
		}
	end
	return types
end

-- Built-ins take their kind, spells and classes from the catalogue, so only what players change is saved.
local function TriggerDefaults()
	local builtin = {}
	for _, def in ipairs(ns.BUILTIN_TRIGGERS) do
		builtin[def.key] = {
			enabled = true,
			message = false,
			color = { r = def.color.r, g = def.color.g, b = def.color.b },
			sound = false,
			area = false,
			sticky = def.sticky,
		}
	end
	return builtin
end

ns.PROFILE_DEFAULTS = {
	enabled = true,
	font = false,
	outline = "",
	shadow = true,
	numbers = "grouped",
	sounds = true,
	noBrackets = false,
	alignIcons = false,
	iconZoom = 16,
	cooldowns = { source = "cdm", minLength = 3 },
	types = TypeDefaults(),
	triggers = { builtin = TriggerDefaults(), custom = {} },
}

-- Presets ------------------------------------------------------------------------------------------------------------

local function Area(fields)
	-- Blizzard's own place: Blizzard's text going up starts a 64 px line below its start point (384) and ends that much
	-- below its end point (609), so its top runs 320 to 545. The box is 250 tall with its bottom at 295, so text starts
	-- with its top a line above the bottom (320) and ends at the top (545), in the same UI-scaled units Blizzard's text
	-- uses, at any UI scale (Styles.Layout).
	local area = {
		width = 300, height = 250,
		style = "blizzard", direction = "up", behavior = false,
		stickyStyle = "blizzard", stickyBehavior = false,
		align = "center",
		duration = 1.9, stickyDuration = 1.9,
		stagger = true,
		overflow = "shift",
		fontSize = 25,
		icons = "left",
		positions = {},
		default = { point = "BOTTOM", x = 0, y = 295 },
	}
	for key, value in pairs(fields) do area[key] = value end
	return area
end

-- MSBT places an area by its bottom-left corner from the screen's centre; CTX by its centre.
local function FromMSBT(offsetX, offsetY, width, height)
	return { point = "CENTER", x = offsetX + width / 2, y = offsetY + height / 2 }
end

-- MSBT's words for misses and the like: the game's own word (MISS and so on, as MSBT uses) with "!".
local function Exclaim(name, fallback)
	return ns.TemplateFromGlobal(name, nil, fallback) .. "!"
end

local function Color(r, g, b)
	return { r = r, g = g, b = b }
end

-- MSBT's colours (msbt.md 2.4).
local RED, BLUE, YELLOW, PURPLE, GREEN, WHITE = Color(1, 0, 0), Color(0, 0, 1), Color(1, 1, 0), Color(0.5, 0, 0.5),
	Color(0, 1, 0), Color(1, 1, 1)
local NOTICE = Color(0.5, 0.5, 0.698)

local function MSBTTypes()
	local types = {}
	local function Set(key, area, color, template, extra)
		local entry = { area = area, color = color, template = template }
		for field, value in pairs(extra or {}) do entry[field] = value end
		types[key] = entry
	end

	local HEALED = "(%n) +%a"
	for _, prefix in ipairs({ "", "SPELL_" }) do
		for _, word in ipairs({ "MISS", "DODGE", "PARRY", "DEFLECT", "EVADE" }) do
			Set(prefix .. word, "incoming", BLUE, Exclaim(word, word:sub(1, 1) .. word:sub(2):lower()))
		end
		Set(prefix .. "IMMUNE", "incoming", YELLOW, Exclaim("IMMUNE", "Immune"))
		Set(prefix .. "REFLECT", "incoming", PURPLE, Exclaim("REFLECT", "Reflect"))
		-- Blocks, absorbs and resists keep Blizzard's message, which has both the full and the partial wording (a type
		-- has one template, and MSBT's "Absorb! <%a>" would drop the damage taken from a partial one).
		Set(prefix .. "BLOCK", "incoming", BLUE, false)
		Set(prefix .. "ABSORB", "incoming", YELLOW, false)
		Set(prefix .. "RESIST", "incoming", PURPLE, false)
	end
	for _, key in ipairs({ "DAMAGE", "DAMAGE_CRIT", "SPELL_DAMAGE", "SPELL_DAMAGE_CRIT", "DAMAGE_SHIELD" }) do
		Set(key, "incoming", RED, "-%a")
	end

	-- MSBT's own sizes, as offsets from its areas' 18: crits and Spell Alerts 26 (+8, set below), heal crits 22 (+4),
	-- low health, low mana and experience 26 (+8), cooldowns 22 (+4).
	Set("HEAL", "incoming", GREEN, HEALED)
	Set("HEAL_CRIT", "incoming", GREEN, HEALED, { sizeOffset = 4 })
	Set("PERIODIC_HEAL", "incoming", GREEN, HEALED)
	Set("PERIODIC_HEAL_CRIT", "incoming", GREEN, HEALED)
	-- MSBT has no shield gained event: Blizzard's message, with the heals.
	Set("ABSORB_ADDED", "incoming", GREEN, false)

	Set("ENERGIZE", "notification", YELLOW, "+%a %p")
	Set("SPELL_AURA_START", "notification", Color(0.698, 0.698, 0), "[%s]")
	Set("SPELL_AURA_START_HARMFUL", "notification", Color(0, 0.5, 0.5), "[%s]")
	Set("SPELL_AURA_END", "notification", Color(0.918, 0.918, 0), "-[%s]")
	Set("SPELL_AURA_END_HARMFUL", "notification", Color(0, 0.835, 0.835), "-[%s]")

	-- Spell Alerts look like MSBT's triggers, which they stand in for.
	Set("SPELL_ACTIVE", "notification", YELLOW, "%s!")
	-- MSBT has no spell cast event: Blizzard's message and colour, with the notifications.
	Set("SPELL_CAST", "notification", false, false)
	Set("FACTION", "notification", NOTICE, "+%a " .. ns.TemplateFromGlobal("REPUTATION", nil, "Reputation") .. " (%s)")
	Set("HONOR_GAINED", "notification", NOTICE, "+%a " .. ns.TemplateFromGlobal("HONOR", nil, "Honour"))
	Set("HEALTH_LOW", "notification", Color(1, 0.5, 0.5), L.TEMPLATE_MSBT_HEALTH_LOW,
		{ sticky = "always", sizeOffset = 8, sound = "MSBT Low Health" })
	Set("MANA_LOW", "notification", Color(0.5, 0.5, 1), L.TEMPLATE_MSBT_MANA_LOW,
		{ sticky = "always", sizeOffset = 8, sound = "MSBT Low Mana" })
	Set("ENTERING_COMBAT", "notification", WHITE, L.TEMPLATE_MSBT_ENTERING_COMBAT)
	Set("LEAVING_COMBAT", "notification", WHITE, L.TEMPLATE_MSBT_LEAVING_COMBAT)

	Set("COOLDOWN", "static", WHITE, L.TEMPLATE_MSBT_COOLDOWN, { sizeOffset = 4, sound = "MSBT Cooldown" })
	Set("LOOT", "static", YELLOW, "+%a %e (%t)", { enabled = true })
	Set("MONEY", "static", WHITE, "+%e", { enabled = true })
	Set("CURRENCY", "static", YELLOW, "+%a %e (%t)", { enabled = true })
	Set("EXPERIENCE", "notification", Color(0.756, 0.270, 0.823),
		"%a " .. ns.TemplateFromGlobal("XP", nil, "XP"), { enabled = false, sticky = "always", sizeOffset = 8 })
	Set("SKILL", "notification", Color(0.333, 0.333, 1), "%s: %a", { enabled = true })
	-- MSBT's crit size, 26 against 18, for every crit type not given its own.
	for _, def in ipairs(ns.TYPES) do
		if def.sticky == true then
			types[def.key] = types[def.key] or {}
			if types[def.key].sizeOffset == nil then types[def.key].sizeOffset = 8 end
		end
	end
	return types
end

-- MSBT's Pow sticky style lasts 0.17 s growing, 1.5 s held and 0.5 s fading (msbt.md 3.7).
local POW_DURATION = 2.17

-- LaryIsland's own MSBT profile, as changes to the MSBT preset: names hidden, crits not sticky and the size of other
-- text (22) with a thick outline, text at 80 % opacity, light blue misses, buffs, power gains, money and low health
-- and mana off, and cooldowns at the normal size with no sound.
local function LaryIslandTypes()
	local types = MSBTTypes()
	local function Change(key, fields)
		types[key] = types[key] or {}
		for field, value in pairs(fields) do types[key][field] = value end
	end

	-- MSBT has no evades taken; they go with the other misses.
	local MISS_BLUE = Color(0, 0.3, 1)
	for _, prefix in ipairs({ "", "SPELL_" }) do
		for _, word in ipairs({ "MISS", "DODGE", "PARRY", "DEFLECT", "EVADE", "BLOCK" }) do
			Change(prefix .. word, { color = MISS_BLUE })
		end
	end
	-- Hide Names: Blizzard's heal, which names the healer only when the game's Friendly Healer Names is on.
	for _, key in ipairs({ "HEAL", "HEAL_CRIT", "PERIODIC_HEAL", "PERIODIC_HEAL_CRIT" }) do
		Change(key, { template = false })
	end
	for _, key in ipairs({ "ENERGIZE", "SPELL_AURA_START", "SPELL_AURA_END", "MONEY", "HEALTH_LOW", "MANA_LOW" }) do
		Change(key, { enabled = false })
	end
	Change("COOLDOWN", { sound = false, sizeOffset = 0, template = false })
	-- Blizzard's own wording for Spell Alerts and low health and mana.
	for _, key in ipairs({ "SPELL_ACTIVE", "HEALTH_LOW", "MANA_LOW" }) do
		Change(key, { template = false })
	end
	-- Crits scroll like other text; Spell Alerts and triggers keep MSBT's trigger size, 26 against 22.
	for _, def in ipairs(ns.TYPES) do
		if def.key:find("_CRIT$") then
			Change(def.key, { sticky = "never", sizeOffset = 0, outline = "THICKOUTLINE" })
		elseif def.sticky == true then
			Change(def.key, { sizeOffset = 4 })
		end
	end
	-- No "!", and Blizzard's message wherever the text is then the same as it.
	for key, entry in pairs(types) do
		if type(entry.template) == "string" then
			local template = entry.template:gsub("!", "")
			local def = ns.TYPE[key]
			entry.template = not (def and template == def.template) and template
		end
	end
	for _, entry in pairs(types) do
		local color = entry.color
		if type(color) == "table" then entry.color = { r = color.r, g = color.g, b = color.b, a = 0.8 } end
	end
	return types
end

-- LaryIsland's animation speed, 80 %: everything lasts 1.25 times as long.
local LARYISLAND_SLOW = 100 / 80

-- MSBT's Straight lasts its height at 260 px per 3 s.
local function StraightDuration(height)
	return height / 260 * 3 * LARYISLAND_SLOW
end

-- One area where Blizzard's text is (Area explains its place).
ns.DEFAULT_AREAS = { main = Area({ name = L.AREA_NAME_MAIN }) }

ns.PRESETS = {
	{
		key = "msbt", label = L.PRESET_MSBT, description = L.PRESET_MSBT_DESC,
		-- MSBT's four areas (MSBTProfiles.lua:119-158, msbt.md 2.2 and 3). Outgoing has nothing to show yet (design
		-- document 4.3), but is there for players to send types to.
		areas = {
			incoming = Area({
				name = L.AREA_NAME_INCOMING, width = 40, height = 260,
				style = "parabola", direction = "down", behavior = "left", align = "right", duration = 3,
				stickyStyle = "pow", stickyBehavior = "jiggle", stickyDuration = POW_DURATION,
				fontSize = 18, default = FromMSBT(-140, -160, 40, 260),
			}),
			outgoing = Area({
				name = L.AREA_NAME_OUTGOING, width = 40, height = 260,
				style = "parabola", direction = "down", behavior = "right", align = "left", duration = 3,
				stickyStyle = "pow", stickyBehavior = "jiggle", stickyDuration = POW_DURATION,
				fontSize = 18, icons = "right", default = FromMSBT(100, -160, 40, 260),
			}),
			notification = Area({
				name = L.AREA_NAME_NOTIFICATION, width = 350, height = 200,
				-- Straight lasts its height at 260 px per 3 s: 200 px is 2.31 s.
				style = "blizzard", direction = "up", align = "center", duration = 2.31,
				stickyStyle = "pow", stickyBehavior = "normal", stickyDuration = POW_DURATION,
				fontSize = 18, default = FromMSBT(-175, 120, 350, 200),
			}),
			static = Area({
				name = L.AREA_NAME_STATIC, width = 40, height = 125,
				style = "static", direction = "down", align = "center", duration = 3.15,
				stickyStyle = "pow", stickyBehavior = "normal", stickyDuration = POW_DURATION,
				fontSize = 18, default = FromMSBT(-20, -300, 40, 125),
			}),
		},
		types = MSBTTypes(),
		-- Its text includes kinds the game's own switches have off by default (misses, auras, power gains, combat state,
		-- reputation), so applying it offers to turn those on (Options.lua).
		gameSwitches = true,
		-- MSBT's font only when another addon shares it (ApplyPreset checks); no outline, a shadow, numbers in full.
		general = { font = "MSBT Porky", outline = "", shadow = true, numbers = "full" },
	},
	{
		key = "laryisland", label = L.PRESET_LARYISLAND, description = L.PRESET_LARYISLAND_DESC,
		-- LaryIsland's MSBT profile: Incoming and Outgoing straight up either side of the character, Notification
		-- below them and Static high above, Pow without Jiggle, no stagger, text size 22, animation speed 80 %. Incoming
		-- and Outgoing stack new lines behind; Notification pushes along.
		areas = {
			incoming = Area({
				name = L.AREA_NAME_INCOMING, width = 40, height = 180,
				style = "blizzard", direction = "up", align = "right", duration = StraightDuration(180),
				stickyStyle = "pow", stickyBehavior = "normal", stickyDuration = POW_DURATION * LARYISLAND_SLOW,
				fontSize = 22, icons = "right", stagger = false, overflow = "stack", default = FromMSBT(-240, -110, 40, 180),
			}),
			outgoing = Area({
				name = L.AREA_NAME_OUTGOING, width = 40, height = 180,
				style = "blizzard", direction = "up", align = "left", duration = StraightDuration(180),
				stickyStyle = "pow", stickyBehavior = "normal", stickyDuration = POW_DURATION * LARYISLAND_SLOW,
				fontSize = 22, stagger = false, overflow = "stack", default = FromMSBT(200, -110, 40, 180),
			}),
			notification = Area({
				name = L.AREA_NAME_NOTIFICATION, width = 350, height = 150,
				style = "blizzard", direction = "up", align = "center", duration = StraightDuration(150),
				stickyStyle = "pow", stickyBehavior = "normal", stickyDuration = POW_DURATION * LARYISLAND_SLOW,
				fontSize = 22, stagger = false, overflow = "push", default = FromMSBT(-175, -150, 350, 150),
			}),
			static = Area({
				name = L.AREA_NAME_STATIC, width = 40, height = 125,
				style = "static", direction = "up", align = "center", duration = 3.15 * LARYISLAND_SLOW,
				stickyStyle = "pow", stickyBehavior = "normal", stickyDuration = POW_DURATION * LARYISLAND_SLOW,
				fontSize = 22, stagger = false, default = FromMSBT(-20, 350, 40, 125),
			}),
		},
		types = LaryIslandTypes(),
		gameSwitches = true,
		-- Cabin when another addon shares it.
		general = { font = "Cabin", outline = "", shadow = true, numbers = "full" },
		-- Cooldowns of 21 s or more (MSBT's threshold), when they come from the spellbook.
		cooldowns = { minLength = 21 },
	},
}
ns.PRESET = {}
for _, preset in ipairs(ns.PRESETS) do
	ns.PRESET[preset.key] = preset
end

-- Applying -----------------------------------------------------------------------------------------------------------

local function Copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, inner in pairs(value) do copy[key] = Copy(inner) end
	return copy
end

-- Shared fonts and sounds the preset names are only used when they're there now; otherwise the game's font, no sound.
local function Usable(kind, value)
	if ns.Media and ns.Media.Has then
		return ns.Media.Has(kind, value) and value or false
	end
	return false
end

-- Replaces the profile's areas with the preset's, or the defaults without one (Core does that for a profile with none).
function ns.ApplyPresetAreas(profile, key)
	local preset = key and ns.PRESET[key]
	profile.areas = Copy(preset and preset.areas or ns.DEFAULT_AREAS)
end

-- The preset in the current profile: its areas, its event types (every type back to its default first, then the
-- preset's own settings), its text style (font, outline, shadow, numbers) and any cooldown settings it has. Profiles,
-- triggers and the other options are left as they are. Callers ask the player first.
-- The text style a preset sets (its `general`), back to the defaults first.
local STYLE_FIELDS = { "font", "outline", "shadow", "numbers" }

function ns.ApplyPreset(key)
	local preset = ns.PRESET[key]
	local profile = ns.profile
	if not (preset and profile) then return end
	ns.ApplyPresetAreas(profile, key)
	for _, settings in pairs(profile.types or {}) do
		for field in pairs(settings) do settings[field] = nil end
	end
	for typeKey, fields in pairs(preset.types) do
		local settings = profile.types[typeKey]
		if settings then
			for field, value in pairs(fields) do
				if field == "sound" then value = Usable("sound", value) end
				settings[field] = Copy(value)
			end
		end
	end
	for _, field in ipairs(STYLE_FIELDS) do profile[field] = Copy(ns.PROFILE_DEFAULTS[field]) end
	for field, value in pairs(preset.general) do
		if field == "font" then value = Usable("font", value) end
		profile[field] = Copy(value)
	end
	if preset.cooldowns then
		profile.cooldowns = profile.cooldowns or {}
		for field, value in pairs(preset.cooldowns) do profile.cooldowns[field] = value end
	end
	ns.Fire("SETTINGS_CHANGED")
	ns.Fire("AREAS_CHANGED")
	ns.Fire("TYPES_CHANGED")
end
