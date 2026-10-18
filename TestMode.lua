local addonName, ns = ...
local L = ns.L

-- /ctx test: made-up text through CTX's real path, so a player alone can see how their areas look and move without
-- anyone hitting them. While it's on, every 0.4 to 0.9 s one of the player's event types (one that's on, and that the
-- game's own switches would let show) shows its sample in its own area, through ns.Router.Sample, as the game would
-- send it, with its sound. The mix is like real combat: mostly damage and heals, some crits, misses, auras, power and
-- cooldowns (one of the player's own tracked spells), and now and then one of the player's triggers.
-- On for this session only; it stops on logging out.
--   ns.TestMode.Toggle()   on or off
--   ns.TestMode.IsOn()

ns.TestMode = {}
local TestMode = ns.TestMode

local MIN_GAP, MAX_GAP = 0.4, 0.9
local TRIGGER_CHANCE = 0.04

-- How often each type comes up, against 1 for the rest. Types left out take their group's weight.
local WEIGHT = {
	DAMAGE = 20, SPELL_DAMAGE = 10, HEAL = 12, PERIODIC_HEAL = 8,
	DAMAGE_CRIT = 4, SPELL_DAMAGE_CRIT = 3, HEAL_CRIT = 3, PERIODIC_HEAL_CRIT = 2,
	ABSORB_ADDED = 2, ENERGIZE = 4, COOLDOWN = 2,
}
local GROUP_WEIGHT = {
	incomingMelee = 1.5, incomingSpells = 1, healing = 1, power = 1, auras = 1.5, notifications = 0.5, ctx = 0.5,
}

local on = false
local generation = 0   -- bumped on every stop, so a timer from an earlier run does nothing

function TestMode.IsOn()
	return on
end

-- Whether the game's own combat text switches would let the type show (CTX's own types have none).
local function GameAllows(def)
	if def.gameSetting then return ns.GameSetting(def.gameSetting) end
	if def.gameSettings then
		for _, cvar in ipairs(def.gameSettings) do
			if ns.GameSetting(cvar) then return true end
		end
		return false
	end
	return true
end

local function TypeSettings(key)
	if ns.Router and ns.Router.TypeSettings then return ns.Router.TypeSettings(key) end
	return ns.profile and ns.profile.types and ns.profile.types[key]
end

-- One type, picked by weight from those that are on now (read each time, so changes show straight away).
local function PickType()
	local total, choices = 0, {}
	for _, def in ipairs(ns.TYPES or {}) do
		local settings = TypeSettings(def.key)
		if not def.internal and settings and settings.enabled and GameAllows(def) then
			local weight = WEIGHT[def.key] or GROUP_WEIGHT[def.group] or 1
			total = total + weight
			choices[#choices + 1] = { key = def.key, upTo = total }
		end
	end
	if total == 0 then return nil end
	local roll = math.random() * total
	for _, choice in ipairs(choices) do
		if roll <= choice.upTo then return choice.key end
	end
	return choices[#choices].key
end

-- Why test mode can't run now, or nil when it can.
local function Problem()
	if not (ns.profile and ns.profile.enabled) then return L.TEST_DISABLED end
	-- Areas run Blizzard's own combat text code, which the game only loads once its setting is on.
	if not (ns.Areas and ns.Areas.Ready and ns.Areas.Ready() and ns.Router and ns.Router.Sample) then
		return L.TEST_NOT_READY:format(SHOW_COMBAT_TEXT_TEXT or L.TEST_GAME_SETTING)
	end
	return nil
end

local Stop

local function Next(run)
	C_Timer.After(MIN_GAP + math.random() * (MAX_GAP - MIN_GAP), function()
		if not on or run ~= generation then return end
		local problem = Problem()
		if problem then
			Stop(problem)
			return
		end
		-- Now and then one of the player's triggers, as it would fire; otherwise a type's sample, with its sound.
		local fired = false
		if math.random() < TRIGGER_CHANCE and ns.Triggers and ns.Triggers.Sample then
			ns.SafeCall("TestMode trigger", function() fired = ns.Triggers.Sample() end)
		end
		if not fired then
			local key = PickType()
			if key then ns.SafeCall("TestMode sample", ns.Router.Sample, key, true) end
		end
		Next(run)
	end)
end

local function Start()
	local problem = Problem()
	if problem then
		ns.Print(problem)
		return
	end
	on = true
	ns.Print(L.TEST_ON)
	if not PickType() then ns.Print(L.TEST_NOTHING_ON) end
	Next(generation)
end

-- reason: why it stopped by itself (printed instead of the usual line), nil when the player turned it off.
Stop = function(reason)
	if not on then return end
	on = false
	generation = generation + 1
	ns.Print(reason or L.TEST_OFF)
end

function TestMode.Toggle()
	if on then Stop() else Start() end
end

ns.On("PLAYER_LOGOUT", function()
	on = false
	generation = generation + 1
end)
