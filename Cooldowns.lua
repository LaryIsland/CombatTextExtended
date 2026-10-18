local addonName, ns = ...

-- Cooldown ready notifications (design document 4.4). Which spells: the ones on Blizzard's own Cooldown Manager
-- (its Essential and Utility viewers, as the player arranged them), or every active spell in the spellbook when the
-- Cooldown Manager is off or the player picks that. How: each spell's isActive, isEnabled and isOnGCD, which the client
-- never hides, checked on every SPELL_UPDATE_COOLDOWN and every 0.1 s while anything is on cooldown. No casts are
-- needed (cast spell IDs can be secret), and talents and resets (Cold Snap, Preparation) just work.
--
--   ns.Cooldowns.IsOnCooldown(spellID)  true / false, or nil when it can't be told
--   ns.Cooldowns.OnReady(fn)            fn(spellID) on every spell that becomes ready
--   ns.Cooldowns.Refresh()              re-reads which spells are tracked
--   ns.Cooldowns.SampleSpell()          name, icon of a tracked spell (test mode's samples), or nil

local Cooldowns = {}
ns.Cooldowns = Cooldowns

local TICK = 0.1
local BANK = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
local SPELL_ITEM = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell or 1

-- Tracked spells by key (the base spell ID), each { key, id (the ID checked), triggerOnly, minimum, seen, onCooldown }.
-- `seen` is false until the first reading, which only records (so nothing fires at login or after a refresh).
local tracked = {}
local byCheckID = {}       -- the ID checked -> its entry, for IsOnCooldown
local lengths = {}         -- cooldown lengths read out of combat, by key, kept for the session (minimum length)
local listeners = {}
local ticker
local refreshQueued

-- Reading one spell -------------------------------------------------------------------------------------------------

-- The client's cooldown for a spell, or nil when there's none to read. isActive, isEnabled and isOnGCD are never
-- secret; startTime and duration can be, so only duration is touched, and only after checking.
local function Read(id)
	local info = C_Spell.GetSpellCooldown(id)
	if type(info) ~= "table" or ns.IsSecret(info.isActive) or ns.IsSecret(info.isEnabled) or ns.IsSecret(info.isOnGCD) then
		return nil
	end
	return info
end

-- Out of combat the duration is usually readable: remembered as the spell's length for the minimum length setting.
local function RememberLength(entry, info)
	if ns.InCombat() or info.isActive ~= true or info.isOnGCD ~= false then return end
	local duration = info.duration
	if ns.IsSecret(duration) or type(duration) ~= "number" or duration <= 0 then return end
	lengths[entry.key] = duration
end

-- The game's base cooldown, as a first guess at the length before the spell has been seen on cooldown out of combat.
-- Undocumented (design document 4.4 [Open]), so anything odd is ignored.
local function BaseLength(id)
	if not GetSpellBaseCooldown or ns.InCombat() then return nil end
	local ok, ms = pcall(GetSpellBaseCooldown, id)
	if not ok or ns.IsSecret(ms) or type(ms) ~= "number" or ms <= 0 then return nil end
	return ms / 1000
end

-- Telling listeners ---------------------------------------------------------------------------------------------------

local function Ready(entry)
	local id = entry.id
	-- A cooldown trigger for this spell shows its own message instead of the plain notification (4.9).
	local handled = ns.Triggers and ns.Triggers.OnReady and ns.Triggers.OnReady(id)
	if not handled and not entry.triggerOnly then
		local minimum = entry.minimum
		local length = lengths[entry.key]
		if not (minimum and length and length < minimum) and ns.Router and ns.Router.Show then
			local name = ns.Readable(C_Spell.GetSpellName(id))
			if type(name) == "string" then
				ns.Router.Show("COOLDOWN", { s = name }, { icon = ns.Readable(C_Spell.GetSpellTexture(id)) })
			end
		end
	end
	for i = 1, #listeners do
		ns.SafeCall("Cooldowns.OnReady", listeners[i], id)
	end
end

-- Checking ------------------------------------------------------------------------------------------------------------

local Check

local function UpdateTicker(anyOnCooldown)
	if anyOnCooldown and not ticker then
		ticker = C_Timer.NewTicker(TICK, function() Check(false) end)
	elseif not anyOnCooldown and ticker then
		ticker:Cancel()
		ticker = nil
	end
end

-- One spell. `inEvent` is true while handling SPELL_UPDATE_COOLDOWN, the only time isOnGCD can be trusted: then a spell
-- is on cooldown when isActive and not isOnGCD, and ready when isActive went false or is true only for the global
-- cooldown. isOnGCD == nil never counts as ended. Between events (the ticker) only isActive going false counts.
-- On hold (Stealth: isEnabled false) counts as on cooldown, and isActive is false then, so it never ends a cooldown.
local function CheckEntry(entry, inEvent)
	local info = Read(entry.id)
	if not info then return end
	RememberLength(entry, info)

	local active, gcd = info.isActive == true, info.isOnGCD
	local onCooldown = entry.onCooldown
	if info.isEnabled == false then
		onCooldown = true
	elseif not active then
		onCooldown = false
	elseif inEvent then
		if gcd == false then
			onCooldown = true
		elseif gcd == true then
			onCooldown = false
		end
	end

	if not entry.seen then
		entry.seen = true
		entry.onCooldown = onCooldown
		return
	end
	local was = entry.onCooldown
	entry.onCooldown = onCooldown
	if was and not onCooldown then
		Ready(entry)
	end
end

-- Between events only a cooldown ending can be seen, so the ticker reads just the spells on cooldown (and any not yet
-- read): every-spell mode can track a whole spellbook.
function Check(inEvent)
	local any = false
	for _, entry in pairs(tracked) do
		if inEvent or entry.onCooldown or not entry.seen then
			CheckEntry(entry, inEvent)
		end
		if entry.onCooldown then any = true end
	end
	UpdateTicker(any)
end

-- Which spells --------------------------------------------------------------------------------------------------------

-- A plain spell ID, or nil (IDs from the client are checked before they're used as keys).
local function PlainID(id)
	if ns.IsSecret(id) or type(id) ~= "number" or id <= 0 then return nil end
	return id
end

local function CooldownManagerOn()
	if not ns.GameSetting("cooldownViewerEnabled") then return false end
	if C_CooldownViewer and C_CooldownViewer.IsCooldownViewerAvailable then
		local available = C_CooldownViewer.IsCooldownViewerAvailable()
		if available ~= true then return false end
	end
	return true
end

-- The spells on the live Essential and Utility viewers, read from their item frames as the player arranged them. Read
-- only: the data provider's rebuild functions write to the active layout, so they're never called. Items without a
-- cooldown (Blizzard's empty placeholders) have no info.
local function AddCooldownManagerSpells(into)
	local found = false
	for _, viewerName in ipairs({ "EssentialCooldownViewer", "UtilityCooldownViewer" }) do
		local viewer = _G[viewerName]
		local items = viewer and viewer.GetItemFrames and viewer:GetItemFrames()
		if type(items) == "table" then
			for _, item in ipairs(items) do
				local info = item.GetCooldownInfo and item:GetCooldownInfo()
				local cooldownID = item.GetCooldownID and item:GetCooldownID()
				if type(info) == "table" and cooldownID ~= nil then
					local base = PlainID(item.GetBaseSpellID and item:GetBaseSpellID() or info.spellID)
					local id = PlainID(info.overrideSpellID) or base
					if base and id and not into[base] then
						into[base] = { id = id }
						found = true
					end
				end
			end
		end
	end
	return found
end

-- Every active, non-passive spell in the player's spellbook (highest rank only), with the profile's minimum length.
local function AddSpellbookSpells(into, minimum)
	local lines = C_SpellBook.GetNumSpellBookSkillLines() or 0
	for line = 1, lines do
		local lineInfo = C_SpellBook.GetSpellBookSkillLineInfo(line)
		if lineInfo and not lineInfo.shouldHide and not lineInfo.offSpecID then
			local first = lineInfo.itemIndexOffset + 1
			for slot = first, lineInfo.itemIndexOffset + lineInfo.numSpellBookItems do
				local item = C_SpellBook.GetSpellBookItemInfo(slot, BANK)
				if item and item.itemType == SPELL_ITEM and not item.isPassive and not item.isOffSpec
					and not (C_SpellBook.IsSpellBookItemLowRank and C_SpellBook.IsSpellBookItemLowRank(slot, BANK)) then
					local base = PlainID(item.actionID)
					local id = PlainID(item.spellID) or base
					if base and id and not into[base] then
						into[base] = { id = id, minimum = minimum }
					end
				end
			end
		end
	end
end

local function Rebuild(reset)
	refreshQueued = false
	local profile = ns.profile
	if not profile then return end

	local wanted = {}
	if profile.enabled ~= false then
		local settings = profile.cooldowns or {}
		local fromManager = settings.source == "cdm" and CooldownManagerOn() and AddCooldownManagerSpells(wanted)
		if not fromManager then
			AddSpellbookSpells(wanted, tonumber(settings.minLength))
		end
		-- A cooldown trigger's spell is watched even if neither list has it; only the trigger shows for it.
		local extra = ns.Triggers and ns.Triggers.CooldownSpells and ns.Triggers.CooldownSpells()
		if type(extra) == "table" then
			for _, id in ipairs(extra) do
				id = PlainID(id)
				if id and not wanted[id] then
					wanted[id] = { id = id, triggerOnly = true }
				end
			end
		end
	end

	-- Spells still tracked keep their state, so a refresh in the middle of a cooldown doesn't lose it; a spell whose
	-- checked ID changed (an override) starts again from a first reading.
	local old = tracked
	tracked, byCheckID = {}, {}
	for key, want in pairs(wanted) do
		local entry = not reset and old[key]
		if not entry or entry.id ~= want.id then
			entry = { key = key, id = want.id, seen = false, onCooldown = false }
		end
		entry.triggerOnly = want.triggerOnly
		entry.minimum = want.minimum
		if entry.minimum and not lengths[key] then
			lengths[key] = BaseLength(want.id)
		end
		tracked[key] = entry
		byCheckID[want.id] = entry
	end
	Check(false)
end

-- Many of the refresh events come in bursts, and the Cooldown Manager updates its items after some of them, so the
-- re-read waits a frame.
local function QueueRefresh()
	if refreshQueued then return end
	refreshQueued = true
	C_Timer.After(0, function()
		if refreshQueued then Rebuild(false) end
	end)
end

-- Public ----------------------------------------------------------------------------------------------------------------

function Cooldowns.Refresh()
	Rebuild(false)
end

function Cooldowns.OnReady(fn)
	if type(fn) == "function" then
		table.insert(listeners, fn)
	end
end

-- True while the spell is on cooldown beyond the global cooldown (or on hold), false when it isn't, nil when it can't be
-- told. Tracked spells answer from their state; others are read now, where isOnGCD may be stale outside
-- SPELL_UPDATE_COOLDOWN, so an unclear reading is nil.
-- One of the tracked spells (not one followed only for triggers), picked at random, for a sample that looks real.
-- steady: the same spell as last time while it's still tracked (previews, which redraw often).
local lastSample
function Cooldowns.SampleSpell(steady)
	local ids = {}
	for _, entry in pairs(tracked) do
		if not entry.triggerOnly then
			if steady and entry.id == lastSample then ids = { entry.id } break end
			ids[#ids + 1] = entry.id
		end
	end
	if #ids == 0 then return nil end
	local id = ids[math.random(#ids)]
	lastSample = id
	local name = ns.Readable(C_Spell.GetSpellName(id))
	if type(name) ~= "string" or name == "" then return nil end
	return name, ns.Readable(C_Spell.GetSpellTexture(id))
end

function Cooldowns.IsOnCooldown(spellID)
	local id = PlainID(spellID)
	if not id then return nil end
	local entry = byCheckID[id] or tracked[id]
	if entry then
		if not entry.seen then return nil end
		return entry.onCooldown
	end
	local info = Read(id)
	if not info then return nil end
	if info.isEnabled == false then return true end
	if info.isActive ~= true then return false end
	if info.isOnGCD == true then return false end
	if info.isOnGCD == false then return true end
	return nil
end

-- Events ----------------------------------------------------------------------------------------------------------------

ns.On("SPELL_UPDATE_COOLDOWN", function()
	-- The payload may merge several updates in one frame, so it only wakes a check of every tracked spell.
	Check(true)
end)

ns.On("PLAYER_ENTERING_WORLD", function()
	-- After login or a loading screen, start every spell from a first reading.
	refreshQueued = false
	Rebuild(true)
end)

for _, event in ipairs({ "SPELLS_CHANGED", "COOLDOWN_VIEWER_DATA_LOADED", "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" }) do
	ns.On(event, QueueRefresh)
end

ns.On("ADDON_LOADED", function(name)
	if name == "Blizzard_CooldownViewer" then QueueRefresh() end
end)

if EventRegistry and EventRegistry.RegisterCallback then
	EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", QueueRefresh, Cooldowns)
end

ns.Listen("DB_READY", QueueRefresh)
ns.Listen("SETTINGS_CHANGED", QueueRefresh)
ns.Listen("TRIGGERS_CHANGED", QueueRefresh)
ns.Listen("GAME_SETTING_CHANGED", function(cvar)
	if cvar == "cooldownViewerEnabled" then QueueRefresh() end
end)
