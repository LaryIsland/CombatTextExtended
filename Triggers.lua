local addonName, ns = ...
local L = ns.L

-- Triggers (design document 4.9): a few kinds of notification for one spell each, with their own message, colour,
-- sound, area and sticky. Built-ins come from the catalogue (ns.BUILTIN_TRIGGERS, settings in
-- profile.triggers.builtin), the player's own from profile.triggers.custom. Only the player's class's triggers run.
--   usable    the spell became usable, or only short of power (C_Spell.IsSpellUsable), and isn't on cooldown
--   aura      the player gained an aura the client lets addons read (C_UnitAuras.GetPlayerAuraBySpellID)
--   cooldown  the spell's cooldown ended (Cooldowns.lua asks through Triggers.OnReady)
-- Blizzard's own Spell Alert for a spell is hidden when a usable trigger for it has just fired (SuppressAlert).

local Triggers = {}
ns.Triggers = Triggers

local KINDS = { usable = true, aura = true, cooldown = true }
local SUPPRESS_WINDOW = 1      -- seconds a usable trigger's firing hides Blizzard's alert of the same name
local DUPLICATE_WINDOW = 0.5   -- seconds within which a cooldown trigger's second ready is the same one

-- Running triggers by kind, each { settings, def, kind, spells = { ids }, names = { [name] = true }, recently,
-- state, lastFired }. `state` is nil until the first reading, which only records.
local running = { usable = {}, aura = {}, cooldown = {} }
local usableByName = {}        -- spell name -> list of running usable triggers
local firedByName = {}         -- spell name -> GetTime() of a usable trigger's last firing
local lastUsableFired          -- GetTime() of any usable trigger's last firing (for alerts with a secret name)
local usableQueued

-- Reading safely --------------------------------------------------------------------------------------------------------

local function Accessible(value)
	if ns.IsSecret(value) then return false end
	if value ~= nil and canaccessvalue and not canaccessvalue(value) then return false end
	if type(value) == "table" and canaccesstable and not canaccesstable(value) then return false end
	return true
end

local function PlainID(id)
	id = tonumber(id)
	if not id or ns.IsSecret(id) or id <= 0 then return nil end
	return id
end

local function SpellName(id)
	local name = ns.Readable(C_Spell.GetSpellName(id))
	return type(name) == "string" and name ~= "" and name or nil
end

local function SpellIcon(id)
	return ns.Readable(C_Spell.GetSpellTexture(id))
end

local function PlayerClass()
	local _, class = UnitClass("player")
	if ns.IsSecret(class) or type(class) ~= "string" then return nil end
	return class
end

-- classes: a list of class files ("WARRIOR"); none or empty means every class.
local function ClassMatches(classes, class)
	if type(classes) ~= "table" or #classes == 0 then return true end
	if not class then return false end
	for _, c in ipairs(classes) do
		if c == class then return true end
	end
	return false
end

-- Built-ins keep their kind, spells and classes in the catalogue; a custom trigger's are in its settings.
local function Spells(settings, def)
	local list = {}
	if def then
		for _, id in ipairs(def.spells or {}) do
			id = PlainID(id)
			if id then list[#list + 1] = id end
		end
	else
		local id = PlainID(settings.spell)
		if id then list[1] = id end
	end
	return list
end

local function Field(t, field)
	local value = t.settings[field]
	if value == nil and t.def then value = t.def[field] end
	return value
end

-- Firing ------------------------------------------------------------------------------------------------------------------

-- The text a trigger shows: the player's own, or the default from the spell's name. Plain text, not a template.
local function MessageFor(settings, name)
	local message = settings and settings.message
	if type(message) == "string" and message ~= "" then return message end
	if not name then return nil end
	return L.TRIGGERS_MESSAGE:format(name)
end

local function Fire(t, id, name, icon)
	if not (ns.Router and ns.Router.Show) then return end
	local message = MessageFor(t.settings, name)
	t.lastFired = GetTime()
	ns.Router.Show("TRIGGER", { s = name }, {
		icon = icon or SpellIcon(id),
		color = Field(t, "color"),
		sound = t.settings.sound,
		area = t.settings.area or nil,   -- nil: the Spell Alerts type's area (Router)
		sticky = Field(t, "sticky"),
		message = message,
	})
end

-- Ability usable ------------------------------------------------------------------------------------------------------

-- True when the trigger fired. Usable here means usable or only short of power (so it fires when the condition
-- happens, as MSBT's did) and not on cooldown beyond the global cooldown: an ability that comes off cooldown while its
-- condition still holds then fires as it becomes castable. Fires only on a change to usable; a reading the client
-- hides changes nothing.
local function CheckUsable(t)
	local read, usableID = false, nil
	for _, id in ipairs(t.spells) do
		local ok, usable, noPower = pcall(C_Spell.IsSpellUsable, id)
		if ok and Accessible(usable) and Accessible(noPower) then
			read = true
			if usable == true or noPower == true then
				local onCooldown = ns.Cooldowns and ns.Cooldowns.IsOnCooldown and ns.Cooldowns.IsOnCooldown(id)
				if onCooldown ~= true then
					usableID = id
					break
				end
			end
		end
	end
	if not read then return false end

	local now = usableID ~= nil
	local was = t.state
	t.state = now
	if was ~= false or not now then return false end

	local recently = tonumber(Field(t, "recently"))
	if recently and t.lastFired and GetTime() - t.lastFired < recently then return false end
	local name = SpellName(usableID)
	if not name then return false end
	Fire(t, usableID, name)
	local time = GetTime()
	lastUsableFired = time
	firedByName[name] = time
	for other in pairs(t.names) do
		firedByName[other] = time
	end
	return true
end

local function RunUsable()
	usableQueued = false
	for _, t in ipairs(running.usable) do
		CheckUsable(t)
	end
end

-- Power changes many times a second, so checks are gathered into one per frame.
local function QueueUsable()
	if usableQueued or #running.usable == 0 then return end
	usableQueued = true
	C_Timer.After(0, function()
		if usableQueued then RunUsable() end
	end)
end

-- Aura gained -----------------------------------------------------------------------------------------------------------

-- True when the client says this aura is secret right now: then a missing aura can't be told from a hidden one.
local function AuraSecret(id)
	if not (C_Secrets and C_Secrets.ShouldSpellAuraBeSecret) then return false end
	local ok, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
	return not ok or ns.IsSecret(secret) or secret == true
end

local function ReadAuraFields(aura)
	return ns.Readable(aura.name), ns.Readable(aura.icon)
end

local function CheckAura(t)
	local read, present, presentID, name, icon = false, false, nil, nil, nil
	for _, id in ipairs(t.spells) do
		if not AuraSecret(id) then
			local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
			if ok and Accessible(aura) then
				read = true
				if aura ~= nil then
					present, presentID = true, id
					local fieldsOK, auraName, auraIcon = pcall(ReadAuraFields, aura)
					if fieldsOK then name, icon = auraName, auraIcon end
					break
				end
			end
		end
	end
	if not read then return end

	local was = t.state
	t.state = present
	if was ~= false or not present then return end
	if type(name) ~= "string" or name == "" then name = SpellName(presentID) end
	if not name then return end
	Fire(t, presentID, name, icon)
end

local function RunAuras()
	for _, t in ipairs(running.aura) do
		CheckAura(t)
	end
end

-- Building the running list -----------------------------------------------------------------------------------------------

local function Rebuild()
	local profile = ns.profile
	if not profile then return end

	-- States carry over for triggers that keep running, so a settings change doesn't count as a first reading.
	local old = {}
	for _, list in pairs(running) do
		for _, t in ipairs(list) do old[t.settings] = t end
	end
	running = { usable = {}, aura = {}, cooldown = {} }
	usableByName = {}

	local class = PlayerClass()
	local saved = profile.triggers or {}
	local function Add(settings, def)
		if type(settings) ~= "table" or settings.enabled == false then return end
		local kind = def and def.kind or settings.kind
		if not KINDS[kind] or not ClassMatches(def and def.classes or settings.classes, class) then return end
		local spells = Spells(settings, def)
		if #spells == 0 then return end
		local t = { settings = settings, def = def, kind = kind, spells = spells, names = {} }
		local previous = old[settings]
		if previous and previous.kind == kind then
			t.state, t.lastFired = previous.state, previous.lastFired
		end
		for _, id in ipairs(spells) do
			local name = SpellName(id)
			if name then
				t.names[name] = true
				if kind == "usable" then
					usableByName[name] = usableByName[name] or {}
					table.insert(usableByName[name], t)
				end
			end
		end
		table.insert(running[kind], t)
	end

	if profile.enabled ~= false then
		local builtin = saved.builtin or {}
		for _, def in ipairs(ns.BUILTIN_TRIGGERS or {}) do
			Add(builtin[def.key], def)
		end
		for _, settings in ipairs(saved.custom or {}) do
			Add(settings, nil)
		end
	end

	-- A first reading of anything new.
	RunUsable()
	RunAuras()
end

-- Public ------------------------------------------------------------------------------------------------------------------

-- True when Blizzard's Spell Alert called `name` should be hidden: a usable trigger for a spell of that name fired
-- within the last second. Blizzard's alert may arrive before the events that wake the triggers, so the triggers for
-- that name are checked now too. In combat the name is secret (beta check), so then any usable trigger firing within
-- the second counts: hiding an unrelated alert that lands in the same second is rarer, and better than doubled text.
function Triggers.SuppressAlert(name)
	if ns.IsSecret(name) then
		if lastUsableFired and GetTime() - lastUsableFired <= SUPPRESS_WINDOW then return true end
		for _, t in ipairs(running.usable) do
			if CheckUsable(t) then return true end
		end
		return false
	end
	if type(name) ~= "string" then return false end
	local fired = firedByName[name]
	if fired and GetTime() - fired <= SUPPRESS_WINDOW then return true end
	local list = usableByName[name]
	if list then
		for _, t in ipairs(list) do
			if CheckUsable(t) then return true end
		end
	end
	return false
end

-- Called by Cooldowns.lua when a spell's cooldown ends. True when a cooldown trigger showed its own message for it, so
-- the plain notification isn't shown as well. Matches by spell ID, or by name (the Cooldown Manager may report another
-- rank's ID).
function Triggers.OnReady(spellID)
	local id = PlainID(spellID)
	if not id or #running.cooldown == 0 then return false end
	local name = SpellName(id)
	local handled = false
	for _, t in ipairs(running.cooldown) do
		local match = name and t.names[name]
		if not match then
			for _, own in ipairs(t.spells) do
				if own == id then match = true break end
			end
		end
		if match and name then
			-- A spell tracked under two IDs (the Cooldown Manager's and the trigger's own) ends twice at once: one message.
			if not (t.lastFired and GetTime() - t.lastFired < DUPLICATE_WINDOW) then
				Fire(t, id, name)
			end
			handled = true
		end
	end
	return handled
end

-- Spell IDs the running cooldown triggers watch, for Cooldowns.lua to track.
function Triggers.CooldownSpells()
	local list = {}
	for _, t in ipairs(running.cooldown) do
		for _, id in ipairs(t.spells) do list[#list + 1] = id end
	end
	return list
end

-- Ordered: built-ins in catalogue order, then the player's own. Each { key (built-in) or index (custom), settings, def
-- (built-in only), builtin }. Only the player's class's unless showAllClasses.
function Triggers.List(showAllClasses)
	local list = {}
	local profile = ns.profile
	if not profile then return list end
	local class = PlayerClass()
	local saved = profile.triggers or {}
	local builtin = saved.builtin or {}
	for _, def in ipairs(ns.BUILTIN_TRIGGERS or {}) do
		local settings = builtin[def.key]
		if settings and (showAllClasses or ClassMatches(def.classes, class)) then
			list[#list + 1] = { key = def.key, settings = settings, def = def, builtin = true }
		end
	end
	for index, settings in ipairs(saved.custom or {}) do
		if showAllClasses or ClassMatches(settings.classes, class) then
			list[#list + 1] = { index = index, settings = settings, builtin = false }
		end
	end
	return list
end

-- The message an entry from List shows (for the Event Types popup): the player's own, or the default from the name of
-- its spell (for a built-in with several, the first the player knows).
-- Fires one of the player's triggers that's on, picked at random, with its own settings (test mode). False if none.
function Triggers.Sample()
	local on = {}
	for _, entry in ipairs(Triggers.List()) do
		if entry.settings.enabled ~= false then on[#on + 1] = entry end
	end
	if #on == 0 then return false end
	local entry = on[math.random(#on)]
	local id = Spells(entry.settings, entry.def)[1]
	if not id then return false end
	Fire({ settings = entry.settings, def = entry.def }, id, SpellName(id) or L.TYPE_SAMPLE_TRIGGER)
	return true
end

function Triggers.Message(entry)
	if type(entry) ~= "table" then return nil end
	local spells = Spells(entry.settings or {}, entry.def)
	local id = spells[1]
	-- IsPlayerSpell is only a deprecation shim on Forever (there when loadDeprecationFallbacks is on), so the spellbook's
	-- own check comes first.
	local known = C_SpellBook and C_SpellBook.IsSpellKnown and function(spellID)
		return C_SpellBook.IsSpellKnown(spellID, Enum.SpellBookSpellBank.Player)
	end or IsPlayerSpell
	if known then
		for _, own in ipairs(spells) do
			if known(own) then id = own break end
		end
	end
	return MessageFor(entry.settings, id and SpellName(id))
end

-- A new trigger of the player's own for the current class. Returns its settings, or nil if the kind or spell is wrong.
function Triggers.Add(kind, spellID)
	local profile = ns.profile
	local id = PlainID(spellID)
	if not profile or not KINDS[kind] or not id then return nil end
	profile.triggers = profile.triggers or {}
	profile.triggers.custom = profile.triggers.custom or {}
	local class = PlayerClass()
	local settings = {
		kind = kind,
		spell = id,
		classes = class and { class } or {},
		enabled = true,
		message = false,
		color = { r = 1, g = 1, b = 0 },
		sound = false,
		area = false,
		sticky = true,
	}
	table.insert(profile.triggers.custom, settings)
	Triggers.Changed()
	return settings
end

-- Deletes one of the player's own triggers. Built-ins can only be turned off.
function Triggers.Remove(settings)
	local custom = ns.profile and ns.profile.triggers and ns.profile.triggers.custom
	if type(custom) ~= "table" then return false end
	for i, s in ipairs(custom) do
		if s == settings then
			table.remove(custom, i)
			Triggers.Changed()
			return true
		end
	end
	return false
end

-- After any change to a trigger's settings.
function Triggers.Changed()
	ns.Fire("TRIGGERS_CHANGED")
end

-- Events ------------------------------------------------------------------------------------------------------------------

for _, event in ipairs({ "SPELL_UPDATE_USABLE", "SPELL_UPDATE_COOLDOWN", "PLAYER_TARGET_CHANGED" }) do
	ns.On(event, QueueUsable)
end
ns.OnUnit("UNIT_POWER_FREQUENT", "player", QueueUsable)
-- The aura update's own payload can be secret tables in combat, so it's not read: each trigger's aura is looked up.
ns.OnUnit("UNIT_AURA", "player", RunAuras)

-- A cooldown ending (seen by the 0.1 s check, between events) can make an ability usable.
if ns.Cooldowns and ns.Cooldowns.OnReady then
	ns.Cooldowns.OnReady(QueueUsable)
end

for _, name in ipairs({ "DB_READY", "LOGIN", "SETTINGS_CHANGED", "TRIGGERS_CHANGED" }) do
	ns.Listen(name, Rebuild)
end
-- Spell names (for matching Blizzard's alerts) and known ranks change with the spellbook.
ns.On("SPELLS_CHANGED", Rebuild)
ns.On("PLAYER_ENTERING_WORLD", Rebuild)
