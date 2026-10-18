local addonName, ns = ...
local L = ns.L

-- What there is to show (design document 4.8, 4.9). Data only: nothing here reads the game's state or hooks anything.
--   ns.GROUPS / ns.GROUP[key]   the Event Types popup's pages, in order
--   ns.TYPES / ns.TYPE[key]     event types: ns.TYPES the 49 players set up, ns.TYPE those plus the internal TRIGGER
--   ns.FEED[blizzardType]       what Blizzard's message types mean and which event type each one shows as
--   ns.BUILTIN_TRIGGERS         the default triggers, in order (ns.BUILTIN_TRIGGER[key] by key)
--   ns.TRIGGER_KINDS            the kinds of trigger, in order
--   ns.TEMPLATE_CODES           the codes templates can use, in order
--   ns.TemplateFromGlobal(name, fills, fallback)  one of the game's strings as a template (below)
--
-- Colours, switches and wording are Blizzard's own (Blizzard_CombatText/Shared/CombatTextConstants.lua and
-- Mainline/CombatTextConstantsOverrides.lua, CombatText.lua's OnEvent). They're copied rather than read, because
-- Blizzard_CombatText only loads once the game's "Scrolling Combat Text for Self" is on, and CTX never loads it.
--
-- Type keys are Blizzard's message type names: a type that covers several of Blizzard's (HEAL also covers HEAL_ABSORB,
-- ENERGIZE covers PERIODIC_ENERGIZE and RUNE) is named after the main one. CTX's own types have names of their own.

-- Templates --------------------------------------------------------------------------------------------------------
-- A template is the text a type shows, with codes for the event's values (%a amount and the rest, ns.TEMPLATE_CODES)
-- and a literal % written %%. Where Blizzard builds its message from one of its global strings, the starting template is
-- built from that same string, so it reads as the game's own text does in any language.

-- A global string as a template: its placeholders (%s, %d, %1$s) become the given codes in order, any other % is kept
-- as a literal. The English fallback is used when the global is missing or has placeholders the codes don't cover.
local function FromGlobal(name, fills, fallback)
	local text = _G[name]
	if type(text) ~= "string" then return fallback end
	fills = fills or {}
	local pieces, count, i, length = {}, 0, 1, #text
	while i <= length do
		local percent = text:find("%", i, true)
		if not percent then
			pieces[#pieces + 1] = text:sub(i)
			break
		end
		pieces[#pieces + 1] = text:sub(i, percent - 1)
		local spec, conversion = text:match("^(%d*%$?[%-%+ #0]*%d*%.?%d*)([sdiuf%%])", percent + 1)
		if conversion == "%" then
			pieces[#pieces + 1] = "%%"
			i = percent + 2
		elseif conversion then
			count = count + 1
			local fill = fills[tonumber(spec:match("^(%d+)%$")) or count]
			if not fill then return fallback end
			pieces[#pieces + 1] = fill
			i = percent + #spec + 2
		else
			pieces[#pieces + 1] = "%%"
			i = percent + 1
		end
	end
	return table.concat(pieces)
end
-- Presets.lua builds the MSBT preset's templates the same way.
ns.TemplateFromGlobal = FromGlobal

-- Blizzard's words for misses and full blocks, absorbs and resists (COMBAT_TEXT_MISS and so on).
local function Word(name, fallback)
	return FromGlobal("COMBAT_TEXT_" .. name, nil, fallback)
end

-- The partial block, absorb and resist trailers (BLOCK_TRAILER " (%d blocked)"), with the amount as %r.
local function Trailer(name, fallback)
	return FromGlobal(name .. "_TRAILER", { "%r" }, fallback)
end

local BLOCKED = Trailer("BLOCK", " (%r blocked)")
local ABSORBED = Trailer("ABSORB", " (%r absorbed)")
local RESISTED = Trailer("RESIST", " (%r resisted)")

-- Groups -------------------------------------------------------------------------------------------------------------

ns.GROUPS = {
	{ key = "incomingMelee", label = L.GROUP_INCOMING_MELEE },
	{ key = "incomingSpells", label = L.GROUP_INCOMING_SPELLS },
	{ key = "healing", label = L.GROUP_HEALING },
	{ key = "auras", label = L.GROUP_AURAS },
	{ key = "notifications", label = L.GROUP_NOTIFICATIONS },
	{ key = "ctx", label = L.GROUP_CTX },
}
ns.GROUP = {}
for _, group in ipairs(ns.GROUPS) do
	group.types = {}   -- type keys in order, filled below
	ns.GROUP[group.key] = group
end

-- Event types --------------------------------------------------------------------------------------------------------
-- Each type (Notes/Architecture.md, Catalogue.lua):
--   key, group, label
--   color            Blizzard's colour for it (CTX's own choice for CTX's types), for previews and CTX's own text
--   sticky           whether Blizzard shows it as "crit" (grows, shrinks and stays): crits and Spell Alerts
--   gameSetting      the game's floatingCombatText*_v2 switch for it, nil when Blizzard always shows it
--   gameSettings     for a type behind more than one switch (power gains): all of them; it's off only when all are off
--   template         the template a player starts from: Blizzard's message as a template
--   partialTemplate  for types Blizzard words two ways (block, absorb, resist and their SPELL_ forms; heals with their
--                    _ABSORB forms): the template for a partial block, absorb or resist, while `template` is the one for
--                    a full one (or a heal with nothing absorbed). For a Blizzard message, which one applies comes from
--                    ns.FEED[blizzardType].partial; for samples and CTX's own text, partial when the values have an `r`.
--   codes            the codes its values can fill
--   sample           readable values for previews, Edit Mode and test mode
--   own              true for CTX's own types (no Blizzard message; CTX always builds the text from `template`)
--   chatType         CTX's types from chat: the game's chat type, whose colour (ChatTypeInfo) the default colour copies
--   internal         true for TRIGGER: not set up as a type (triggers carry their own settings), in no group
--   defaultEnabled

local function Color(r, g, b)
	return { r = r, g = g, b = b }
end

-- Blizzard's colours (CombatTextTypeInfo).
local RED = { 1, 0.1, 0.1 }
local PURPLE = { 0.79, 0.3, 0.85 }
local WHITE = { 1, 1, 1 }
local GREEN = { 0.1, 1, 0.1 }
local BLUE = { 0.1, 0.1, 1 }
local GOLD = { 1, 0.82, 0 }

local MISSES = "floatingCombatTextDodgeParryMiss_v2"
local REDUCTION = "floatingCombatTextDamageReduction_v2"

-- Readable sample values. Names are made up, or the game's own words where it has them.
local function Item(name)
	return "|cffffffff[" .. name .. "]|r"
end
local SAMPLE_MONEY = type(GetMoneyString) == "function" and GetMoneyString(123456, true) or "12g 34s 56c"

ns.TYPES, ns.TYPE = {}, {}

local function Type(key, group, color, fields)
	local entry = fields or {}
	entry.key = key
	entry.group = group
	entry.label = L["TYPE_" .. key]
	entry.color = Color(color[1], color[2], color[3])
	entry.sticky = entry.sticky == true
	entry.codes = entry.codes or {}
	entry.sample = entry.sample or {}
	if entry.defaultEnabled == nil then entry.defaultEnabled = true end
	ns.TYPE[key] = entry
	if group then
		ns.TYPES[#ns.TYPES + 1] = entry
		table.insert(ns.GROUP[group].types, key)
	end
	return entry
end

-- Incoming melee (12) and incoming spells (13). Misses and full blocks, absorbs and resists are Blizzard's words
-- (CombatText.lua: _G["COMBAT_TEXT_" .. type], or COMBAT_TEXT_<word> for the SPELL_ forms).
local function Miss(key, group, color, word, fallback)
	return Type(key, group, color, { gameSetting = MISSES, template = Word(word, fallback) })
end

-- A partial block, absorb or resist is "-<damage taken> <trailer>" (CombatText.lua:247-269).
local function Reduction(key, group, color, word, fallback, trailer)
	return Type(key, group, color, {
		gameSetting = REDUCTION, template = Word(word, fallback), partialTemplate = "-%a" .. trailer,
		codes = { "a", "r" }, sample = { a = 1234, r = 321 },
	})
end

Type("DAMAGE", "incomingMelee", RED, { template = "-%a", codes = { "a" }, sample = { a = 1234 } })
Type("DAMAGE_CRIT", "incomingMelee", RED, { sticky = true, template = "-%a", codes = { "a" }, sample = { a = 2468 } })
Miss("MISS", "incomingMelee", RED, "MISS", "Miss")
Miss("DODGE", "incomingMelee", RED, "DODGE", "Dodge")
Miss("PARRY", "incomingMelee", RED, "PARRY", "Parry")
Reduction("BLOCK", "incomingMelee", RED, "BLOCK", "Block", BLOCKED)
Miss("DEFLECT", "incomingMelee", RED, "DEFLECT", "Deflect")
Reduction("ABSORB", "incomingMelee", RED, "ABSORB", "Absorb", ABSORBED)
Miss("IMMUNE", "incomingMelee", RED, "IMMUNE", "Immune")
Miss("EVADE", "incomingMelee", RED, "EVADE", "Evade")
Miss("REFLECT", "incomingMelee", RED, "REFLECT", "Reflect")
Reduction("RESIST", "incomingMelee", RED, "RESIST", "Resist", RESISTED)

Type("SPELL_DAMAGE", "incomingSpells", PURPLE, { template = "-%a", codes = { "a" }, sample = { a = 1234 } })
Type("SPELL_DAMAGE_CRIT", "incomingSpells", PURPLE, {
	sticky = true, template = "-%a", codes = { "a" }, sample = { a = 2468 },
})
Type("DAMAGE_SHIELD", "incomingSpells", PURPLE, { template = "-%a", codes = { "a" }, sample = { a = 123 } })
Miss("SPELL_MISS", "incomingSpells", WHITE, "MISS", "Miss")
Miss("SPELL_DODGE", "incomingSpells", WHITE, "DODGE", "Dodge")
Miss("SPELL_PARRY", "incomingSpells", WHITE, "PARRY", "Parry")
Reduction("SPELL_BLOCK", "incomingSpells", WHITE, "BLOCK", "Block", BLOCKED)
Miss("SPELL_DEFLECT", "incomingSpells", WHITE, "DEFLECT", "Deflect")
Reduction("SPELL_ABSORB", "incomingSpells", PURPLE, "ABSORB", "Absorb", ABSORBED)
Miss("SPELL_IMMUNE", "incomingSpells", WHITE, "IMMUNE", "Immune")
Miss("SPELL_EVADE", "incomingSpells", WHITE, "EVADE", "Evade")
Miss("SPELL_REFLECT", "incomingSpells", WHITE, "REFLECT", "Reflect")
Reduction("SPELL_RESIST", "incomingSpells", PURPLE, "RESIST", "Resist", RESISTED)

-- Healing (5). Blizzard's heal is "+amount", with " [healer]" only when the game's Friendly Healer Names is on (off by
-- default), and the _ABSORB forms add the absorb trailer (CombatText.lua:163-197).
local function Heal(key, crit, amount)
	return Type(key, "healing", GREEN, {
		sticky = crit, template = "+%a", partialTemplate = "+%a" .. ABSORBED,
		codes = { "a", "n", "r" }, sample = { a = amount, n = L.TYPE_SAMPLE_HEALER },
	})
end
Heal("HEAL", false, 1234)
Heal("HEAL_CRIT", true, 2468)
Heal("PERIODIC_HEAL", false, 456)
Heal("PERIODIC_HEAL_CRIT", true, 912)
-- "+amount(Absorb)", no space, as Blizzard writes it (CombatText.lua:281-286).
Type("ABSORB_ADDED", "healing", GREEN, {
	template = "+%a(" .. Word("ABSORB", "Absorb") .. ")", codes = { "a", "n" },
	sample = { a = 1500, n = L.TYPE_SAMPLE_HEALER },
})

-- Power gains, on the notifications page (first there). Blizzard colours each power gain by its power type
-- (GetPowerBarColor); this is the colour it starts from.
Type("ENERGIZE", "notifications", BLUE, {
	gameSetting = "floatingCombatTextEnergyGains_v2",
	gameSettings = { "floatingCombatTextEnergyGains_v2", "floatingCombatTextPeriodicEnergyGains_v2" },
	template = "+%a %p", codes = { "a", "p" },
	sample = { a = 25, p = type(MANA) == "string" and MANA or "Mana" },
	-- A changed template that names the power (%p) can't be built while the power's token is hidden, as it is in
	-- combat: Blizzard's own message, which names it, is shown instead (Router.FromBlizzard).
	requires = { "p" },
	-- Previews and samples show the player's own power, in the colour the game gives it (GetPowerBarColor, as
	-- Blizzard's CombatTextUtil.GetBasicPowerTypeColor), rather than always mana.
	liveSample = function()
		if not UnitPowerType then return nil end
		local _, token = UnitPowerType("player")
		token = ns.Readable(token)
		local name = type(token) == "string" and _G[token]
		if type(name) ~= "string" then return nil end
		local color = GetPowerBarColor and GetPowerBarColor(token)
		return { a = 25, p = name }, color
	end,
})

-- Auras (4).
local AURAS = "floatingCombatTextAuras_v2"
local FADES = FromGlobal("AURA_END", { "%s" }, "<%s> fades")
Type("SPELL_AURA_START", "auras", GREEN, {
	gameSetting = AURAS, template = "<%s>", codes = { "s" }, sample = { s = L.TYPE_SAMPLE_BUFF },
})
Type("SPELL_AURA_START_HARMFUL", "auras", RED, {
	gameSetting = AURAS, template = "<%s>", codes = { "s" }, sample = { s = L.TYPE_SAMPLE_DEBUFF },
})
Type("SPELL_AURA_END", "auras", GREEN, {
	gameSetting = AURAS, template = FADES, codes = { "s" }, sample = { s = L.TYPE_SAMPLE_BUFF },
})
Type("SPELL_AURA_END_HARMFUL", "auras", RED, {
	gameSetting = AURAS, template = FADES, codes = { "s" }, sample = { s = L.TYPE_SAMPLE_DEBUFF },
})

-- Notifications (8). The four Blizzard's frame makes itself are its global strings as they are (_G[type]).
Type("SPELL_ACTIVE", "notifications", GOLD, {
	sticky = true, gameSetting = "floatingCombatTextReactives_v2", template = "<%s>", codes = { "s" },
	sample = { s = L.TYPE_SAMPLE_SPELL_ALERT },
})
Type("SPELL_CAST", "notifications", GREEN, { template = "<%s>", codes = { "s" }, sample = { s = L.TYPE_SAMPLE_CAST } })
-- Blizzard puts "+" in front of a gain itself (it reads the amount); a loss shows as "-50" in its message, but as "+-50"
-- in this template, since CTX can't test an amount that may be secret.
Type("FACTION", "notifications", BLUE, {
	gameSetting = "floatingCombatTextRepChanges_v2", template = "(%s +%a)", codes = { "s", "a" },
	sample = { s = L.TYPE_SAMPLE_FACTION, a = 250 },
})
Type("HONOR_GAINED", "notifications", BLUE, {
	gameSetting = "floatingCombatTextHonorGains_v2",
	template = FromGlobal("COMBAT_TEXT_HONOR_GAINED", { "+%a" }, "Honor +%a"), codes = { "a" }, sample = { a = 198 },
})
local LOW = "floatingCombatTextLowManaHealth_v2"
local COMBAT_STATE = "floatingCombatTextCombatState_v2"
Type("HEALTH_LOW", "notifications", RED, { gameSetting = LOW, template = FromGlobal("HEALTH_LOW", nil, "Health Low") })
Type("MANA_LOW", "notifications", RED, { gameSetting = LOW, template = FromGlobal("MANA_LOW", nil, "Mana Low") })
Type("ENTERING_COMBAT", "notifications", RED, {
	gameSetting = COMBAT_STATE, template = FromGlobal("ENTERING_COMBAT", nil, "Entering Combat"),
})
Type("LEAVING_COMBAT", "notifications", RED, {
	gameSetting = COMBAT_STATE, template = FromGlobal("LEAVING_COMBAT", nil, "Leaving Combat"),
})

-- CTX's own (6). Blizzard has no combat text for these, so their templates are CTX's own lines, and the chat types'
-- colours are the game's default chat colours (players can recolour chat; the Router may prefer ChatTypeInfo's live
-- colour through `chatType`). Only cooldowns are on by default: the game already shows the rest in chat.
Type("COOLDOWN", "ctx", WHITE, {
	own = true, template = L.TEMPLATE_COOLDOWN, codes = { "s" }, sample = { s = L.TYPE_SAMPLE_COOLDOWN },
	-- One of the player's own tracked spells, with its icon.
	liveSample = function(preview)
		if not (ns.Cooldowns and ns.Cooldowns.SampleSpell) then return nil end
		local name, icon = ns.Cooldowns.SampleSpell(preview)
		if name then return { s = name }, nil, icon end
	end,
})
Type("LOOT", "ctx", { 0, 0.67, 0 }, {
	own = true, chatType = "LOOT", template = L.TEMPLATE_LOOT, codes = { "a", "e", "t" },
	sample = { a = 2, e = Item(L.TYPE_SAMPLE_ITEM), t = 12 }, defaultEnabled = false,
})
Type("MONEY", "ctx", { 1, 1, 0 }, {
	own = true, chatType = "MONEY", template = L.TEMPLATE_MONEY, codes = { "e" }, sample = { e = SAMPLE_MONEY },
	defaultEnabled = false,
})
Type("CURRENCY", "ctx", { 0, 0.67, 0 }, {
	own = true, chatType = "CURRENCY", template = L.TEMPLATE_CURRENCY, codes = { "a", "e", "t" },
	sample = { a = 1, e = Item(L.TYPE_SAMPLE_CURRENCY), t = 7 }, defaultEnabled = false,
})
Type("EXPERIENCE", "ctx", { 0.44, 0.44, 1 }, {
	own = true, chatType = "COMBAT_XP_GAIN", template = L.TEMPLATE_EXPERIENCE, codes = { "a", "n" },
	sample = { a = 1234 }, defaultEnabled = false,
})
Type("SKILL", "ctx", { 0.33, 0.33, 1 }, {
	own = true, chatType = "SKILL", template = L.TEMPLATE_SKILL, codes = { "s", "a" },
	sample = { s = L.TYPE_SAMPLE_SKILL, a = 151 }, defaultEnabled = false,
})

-- Triggers' text (4.9). Each trigger has its own colour, sound, area and sticky, so this type only gives their template
-- and a colour for previews (Spell Alerts', which triggers stand in for).
Type("TRIGGER", nil, GOLD, {
	own = true, internal = true, sticky = true, template = L.TEMPLATE_TRIGGER, codes = { "s" },
	sample = { s = L.TYPE_SAMPLE_TRIGGER },
})

-- Blizzard's messages ------------------------------------------------------------------------------------------------
-- ns.FEED[blizzardType] = { type = typeKey, values = function(data, arg3, arg4) return { codes } end, partial = fn }
-- `values` turns C_CombatText.GetCurrentEventInfo's three values (named as in Blizzard's OnEvent) into template codes
-- (design document 2.2). They may be secret: they're only placed in the table, never tested or compared. Only called
-- for a type whose template was changed, so the small table per line costs nothing otherwise.
-- `partial(data, arg3, arg4)`, on Blizzard types that have a partialTemplate: true when Blizzard shows its partial
-- message, false for the full one, nil when that can't be told without reading a secret (the Router then shows
-- Blizzard's own message). Feed types without it are never partial.
-- Blizzard's four types made from other events (HEALTH_LOW, MANA_LOW, ENTERING_COMBAT, LEAVING_COMBAT) and RUNE
-- carry no values.

ns.FEED = {}

local function NoValues()
	return {}
end
local function Amount(data)
	return { a = data }
end
local function Reduced(data, arg3)
	return { a = data, r = arg3 }
end
local function Named(data)
	return { s = data }
end
local function Healed(data, arg3)
	return { n = data, a = arg3 }
end
local function HealedAbsorbed(data, arg3, arg4)
	return { n = data, a = arg3, r = arg4 }
end
local function Always()
	return true
end
-- Blizzard: partial whenever there's a reduced amount (CombatText.lua:247-269).
local function HasReduced(_, arg3)
	return ns.Present(arg3)
end
-- Blizzard's absorb is only partial when some damage got through too (`arg3 and data > 0`), which can't be tested
-- while the amount is secret.
local function AbsorbPartial(data, arg3)
	if not ns.Present(arg3) then return false end
	if ns.IsSecret(data) then return nil end
	return type(data) == "number" and data > 0
end

local function Feed(feedType, typeKey, values, partial)
	ns.FEED[feedType] = { type = typeKey, values = values, partial = partial }
end

for _, key in ipairs({ "DAMAGE", "DAMAGE_CRIT", "SPELL_DAMAGE", "SPELL_DAMAGE_CRIT", "DAMAGE_SHIELD", "HONOR_GAINED" }) do
	Feed(key, key, Amount)
end
for _, key in ipairs({ "MISS", "DODGE", "PARRY", "DEFLECT", "IMMUNE", "EVADE", "REFLECT" }) do
	Feed(key, key, NoValues)
	Feed("SPELL_" .. key, "SPELL_" .. key, NoValues)
end
for _, key in ipairs({ "BLOCK", "RESIST", "SPELL_BLOCK", "SPELL_RESIST" }) do
	Feed(key, key, Reduced, HasReduced)
end
Feed("ABSORB", "ABSORB", Reduced, AbsorbPartial)
Feed("SPELL_ABSORB", "SPELL_ABSORB", Reduced, AbsorbPartial)

-- Heals: the healer's name, then the amount; the _ABSORB forms add the amount absorbed and show as the same type.
for _, key in ipairs({ "HEAL", "HEAL_CRIT", "PERIODIC_HEAL", "PERIODIC_HEAL_CRIT" }) do
	Feed(key, key, Healed)
end
Feed("HEAL_ABSORB", "HEAL", HealedAbsorbed, Always)
Feed("HEAL_CRIT_ABSORB", "HEAL_CRIT", HealedAbsorbed, Always)
Feed("PERIODIC_HEAL_ABSORB", "PERIODIC_HEAL", HealedAbsorbed, Always)
-- A shield: the caster's name, then the amount.
Feed("ABSORB_ADDED", "ABSORB_ADDED", Healed)

-- Power: the amount, and the power's token ("MANA"), shown by the game's name for it (_G.MANA) when it can be read.
local function Energized(data, arg3)
	local token = ns.Readable(arg3)
	local name = type(token) == "string" and _G[token] or nil
	return { a = data, p = type(name) == "string" and name or nil }
end
Feed("ENERGIZE", "ENERGIZE", Energized)
Feed("PERIODIC_ENERGIZE", "ENERGIZE", Energized)
Feed("RUNE", "ENERGIZE", NoValues)
-- Combo point gains, which Blizzard shows as "<total Combo Points>" (CombatText.lua:184-206) in the Power Gain type.
-- Blizzard.lua passes them on with the player's readable total as their value; with Remove < > they're the game's
-- wording without its < > ("3 Combo Points"). The player's own Power Gain text isn't used for them (its %a is the
-- amount gained, not a total).
local COMBO_NAME = type(COMBO_POINTS) == "string" and COMBO_POINTS or "Combo Points"
local function ComboTotal(total)
	return { a = ns.Readable(total), p = COMBO_NAME }
end
Feed("COMBO_POINTS", "ENERGIZE", ComboTotal)
ns.FEED.COMBO_POINTS.wording = "%a %p"

for _, key in ipairs({ "SPELL_AURA_START", "SPELL_AURA_START_HARMFUL", "SPELL_AURA_END", "SPELL_AURA_END_HARMFUL",
	"SPELL_ACTIVE", "SPELL_CAST" }) do
	Feed(key, key, Named)
end
Feed("FACTION", "FACTION", function(data, arg3) return { s = data, a = arg3 } end)

for _, key in ipairs({ "HEALTH_LOW", "MANA_LOW", "ENTERING_COMBAT", "LEAVING_COMBAT" }) do
	Feed(key, key, NoValues)
end

-- Triggers (4.9) -----------------------------------------------------------------------------------------------------
-- The defaults, from MSBT's: yellow, sticky, shown in the Spell Alerts type's area. `recently` is the least time in
-- seconds between two firings. Usable-ability triggers also need the ability off cooldown (Triggers.lua).

ns.TRIGGER_KINDS = {
	{ key = "usable", label = L.TRIGGER_KIND_USABLE },
	{ key = "aura", label = L.TRIGGER_KIND_AURA },
	{ key = "cooldown", label = L.TRIGGER_KIND_COOLDOWN },
}

local function Trigger(key, kind, spells, classes, recently)
	return {
		key = key, kind = kind, spells = spells, classes = classes, recently = recently,
		color = Color(1, 1, 0), sticky = true,
	}
end

ns.BUILTIN_TRIGGERS = {
	Trigger("EXECUTE", "usable", { 5308 }, { "WARRIOR" }),
	Trigger("OVERPOWER", "usable", { 7384 }, { "WARRIOR" }, 2),
	Trigger("REVENGE", "usable", { 6572 }, { "WARRIOR" }, 2),
	Trigger("HAMMER_OF_WRATH", "usable", { 24275 }, { "PALADIN" }),
	-- Omen of Clarity (druid), Arcane Concentration (mage), Elemental Focus (shaman). Whether it can be read in combat
	-- is design document beta check 17.
	Trigger("CLEARCASTING", "aura", { 16870, 12536, 16246 }, { "DRUID", "MAGE", "SHAMAN" }),
}
ns.BUILTIN_TRIGGER = {}
for _, trigger in ipairs(ns.BUILTIN_TRIGGERS) do
	ns.BUILTIN_TRIGGER[trigger.key] = trigger
end

-- Template codes (Notes/Architecture.md), in the order the Event Types popup lists them.
ns.TEMPLATE_CODES = {
	{ code = "a", label = L.TEMPLATE_CODE_A },
	{ code = "n", label = L.TEMPLATE_CODE_N },
	{ code = "s", label = L.TEMPLATE_CODE_S },
	{ code = "p", label = L.TEMPLATE_CODE_P },
	{ code = "r", label = L.TEMPLATE_CODE_R },
	{ code = "e", label = L.TEMPLATE_CODE_E },
	{ code = "t", label = L.TEMPLATE_CODE_T },
}
