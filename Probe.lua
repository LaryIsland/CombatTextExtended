local addonName, ns = ...

-- The beta checks probe (/ctx probe, design document 5), for development only: it isn't packaged (the TOC's
-- do-not-package block) and it's in English, as debug tooling isn't translated. While recording, it notes what the
-- client lets addon code see, without ever keeping a secret value (only what kind of value it was):
--   - every COMBAT_TEXT_UPDATE type, and for each GetCurrentEventInfo value whether it's secret, in and out of combat
--     and in instances, with the game's switches off too (checks 1-3)
--   - what string operations and text widths do with the first secret string and number seen (checks 4, 5)
--   - how Blizzard's AddMessage calls pair with its OnEvent (checks 11, 16)
--   - the game's combat text settings and whether an addon may set one (check 18), and any action the game blocked
--   - COMBAT_LOG_MESSAGE and C_CombatLog.IsCombatLogRestricted (checks 6-8)
--   - the Cooldown Manager's items, its alerts, and when SPELL_UPDATE_COOLDOWN fires against isActive turning false
--     (checks 10, 12, 14)
--   - C_Spell.IsSpellUsable for the class's trigger spells, and Clearcasting (checks 15, 17)
-- Findings are saved in ns.global.probe and shown in a box to copy. Recording carries on across reloads until stopped.
--   /ctx probe start   start recording afresh
--   /ctx probe stop
--   /ctx probe show

ns.Probe = {}
local Probe = ns.Probe

local MAX_LOG = 50              -- cooldown ends kept with their timings
local MAX_TRACKED = 60          -- spells whose cooldowns are followed
local POLL = 0.1                -- how often cooldowns on their way out are checked, as Cooldowns.lua does
local THROTTLE = 0.25           -- aura and usable checks at most this often
local NEXT_EVENT_WAIT = 3       -- how long a cooldown that ended between events waits for the next event

local CLEARCASTING = { 16870, 12536, 16246 }
local ATLASES = { "editmode-up-arrow", "editmode-down-arrow" }
-- Set to its own value to see whether addons may set the game's combat text settings. Text on Target: drawn by the
-- game, so no Lua reacts to it.
local SETCVAR_TEST = "floatingCombatTextCombatDamage_v2"
local CVARS = {
	"enableFloatingCombatText", "floatingCombatTextFloatMode_v2", "classicStyleWorldText",
	"floatingCombatTextDodgeParryMiss_v2", "floatingCombatTextDamageReduction_v2", "floatingCombatTextRepChanges_v2",
	"floatingCombatTextReactives_v2", "floatingCombatTextFriendlyHealers_v2", "floatingCombatTextCombatState_v2",
	"floatingCombatTextCombatHealingAbsorbSelf_v2", "floatingCombatTextComboPoints_v2",
	"floatingCombatTextLowManaHealth_v2", "floatingCombatTextEnergyGains_v2", "floatingCombatTextPeriodicEnergyGains_v2",
	"floatingCombatTextHonorGains_v2", "floatingCombatTextAuras_v2", "floatingCombatTextAuraFade_v2",
	"floatingCombatTextCombatDamage_v2", "floatingCombatTextCombatLogPeriodicSpells_v2",
	"floatingCombatTextCombatHealing_v2", "floatingCombatTextCombatHealingAbsorbTarget_v2",
	"floatingCombatTextSpellMechanics_v2", "floatingCombatTextSpellMechanicsOther_v2",
	"floatingCombatTextCombatDamageAllAutos_v2", "floatingCombatTextPetMeleeDamage_v2",
	"floatingCombatTextPetSpellDamage_v2", "WorldTextScale_v2", "cooldownViewerEnabled",
}
local EVENTS = {
	"COMBAT_TEXT_UPDATE", "COMBAT_LOG_MESSAGE", "SPELL_UPDATE_COOLDOWN", "SPELL_UPDATE_USABLE",
	"ACTIONBAR_UPDATE_USABLE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD",
	"ZONE_CHANGED_NEW_AREA", "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "COOLDOWN_VIEWER_DATA_LOADED",
}
local UNIT_EVENTS = { "UNIT_AURA", "UNIT_SPELLCAST_SUCCEEDED" }

local data                      -- ns.global.probe while recording
local running = false
local frame = CreateFrame("Frame")
local ticker

-- Values as text ------------------------------------------------------------------------------------------------------

local IsSecret = ns.IsSecret

local function ErrorText(err)
	if IsSecret(err) then return "<secret>" end
	return (tostring(err):gsub("^[^:]*:%d+: ", ""))
end

-- Values as text, with secret ones said as such (Pitiful Loot's probe).
local function Text(...)
	local parts = {}
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if IsSecret(value) then
			parts[i] = "<secret>"
		elseif type(value) == "table" then
			local inner = {}
			for k, v in pairs(value) do
				inner[#inner + 1] = (IsSecret(k) and "<secret>" or tostring(k)) .. "=" .. Text(v)
			end
			table.sort(inner)
			parts[i] = "{" .. table.concat(inner, ", ") .. "}"
		else
			parts[i] = tostring(value)
		end
	end
	return table.concat(parts, ", ")
end

local function Try(f, ...)
	if type(f) ~= "function" then return "<not in this client>" end
	return (function(ok, ...)
		if not ok then return "<error: " .. ErrorText((...)) .. ">" end
		return Text(...)
	end)(pcall(f, ...))
end

-- What kind of value it is: "number", "secret string" and so on. type() works on secrets.
local function Kind(value)
	return (IsSecret(value) and "secret " or "") .. type(value)
end

local function Count(...)
	return select("#", ...), ...
end

-- Where the player is now: "out" or "combat", plus "+instance".
local function Context()
	local where = ns.InCombat() and "combat" or "out"
	if IsInInstance() then where = where .. "+instance" end
	return where
end

local function Sub(tbl, key)
	tbl[key] = tbl[key] or {}
	return tbl[key]
end

local function Bump(tbl, key, by)
	tbl[key] = (tbl[key] or 0) + (by or 1)
end

local function SpellName(id)
	local ok, name = pcall(C_Spell.GetSpellName, id)
	if ok and type(name) == "string" and not IsSecret(name) then return name end
	return "?"
end

-- Combat text feed (checks 1-5) ---------------------------------------------------------------------------------------

-- Whether the game's own switch for this Blizzard type is off now (nil when it has none).
local function SwitchOff(feedType)
	local feed = ns.FEED and ns.FEED[feedType]
	local def = feed and ns.TYPE and ns.TYPE[feed.type]
	if not def then return nil end
	if def.gameSetting then return not ns.GameSetting(def.gameSetting) end
	if def.gameSettings then
		for _, cvar in ipairs(def.gameSettings) do
			if ns.GameSetting(cvar) then return false end
		end
		return true
	end
	return nil
end

local OPS = {
	{ "..", function(v) return "x" .. v end },
	{ "string.format %s", function(v) return string.format("%s", v) end },
	{ "string.gsub", function(v) return (string.gsub(v, "1", "2")) end },
	{ "tostring", function(v) return tostring(v) end },
}

local function Outcome(fn, value)
	local ok, result = pcall(fn, value)
	if not ok then return "error: " .. ErrorText(result) end
	return "works, gives a " .. Kind(result)
end

-- Whether a font string's width is secret after it's given secret text: on a hidden font string of an invisible
-- frame, emptied again with ClearText (which also drops the secret aspect).
local measure
local function Widths(value)
	if not measure then
		local holder = CreateFrame("Frame", nil, UIParent)
		holder:SetSize(1, 1)
		holder:SetPoint("CENTER")
		holder:SetAlpha(0)
		measure = holder:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		measure:Hide()
	end
	local ok, err = pcall(measure.SetText, measure, value)
	if not ok then return "SetText error: " .. ErrorText(err) end
	local parts = {}
	for _, method in ipairs({ "GetStringWidth", "GetUnboundedStringWidth" }) do
		local okWidth, width = pcall(measure[method], measure)
		parts[#parts + 1] = method .. ": " .. (okWidth and Kind(width) or ("error: " .. ErrorText(width)))
	end
	if measure.ClearText then pcall(measure.ClearText, measure) else pcall(measure.SetText, measure, "") end
	return table.concat(parts, ", ")
end

-- The first secret string and the first secret number seen, tested once each.
local function TestSecret(value, where)
	local kind = type(value)
	if kind ~= "string" and kind ~= "number" then return end
	local ops = Sub(data, "secretOps")
	if ops[kind] then return end
	local result = { context = where }
	for _, op in ipairs(OPS) do
		result[op[1]] = Outcome(op[2], value)
	end
	result.width = Widths(value)
	ops[kind] = result
end

local function OnCombatTextUpdate(messageType)
	local where = Context()
	local feed = Sub(data, "feed")
	local rec
	if IsSecret(messageType) or type(messageType) ~= "string" then
		rec = Sub(feed, "<" .. Kind(messageType) .. " type>")
	else
		rec = Sub(feed, messageType)
		if SwitchOff(messageType) then Bump(rec, "with its switch off") end
	end
	Bump(rec, where)
	if not ns.GameSetting("enableFloatingCombatText") then Bump(rec, "with the game's combat text off") end
	local ok, n, a, b, c = pcall(function() return Count(C_CombatText.GetCurrentEventInfo()) end)
	if not ok then
		Bump(rec, "GetCurrentEventInfo error")
		return
	end
	Bump(Sub(rec, "values returned"), tostring(n))
	local values = { a, b, c }
	for i = 1, 3 do
		local value = values[i]
		Bump(Sub(rec, "value " .. i), where .. " " .. Kind(value))
		if IsSecret(value) then TestSecret(value, where) end
	end
end

-- Blizzard's frame (checks 11, 16) ------------------------------------------------------------------------------------
-- Counts the AddMessage calls each OnEvent made. Calls no OnEvent picked up by the next frame happened outside it.

local pending, orphanCheck, hookedBlizzard = 0, false, false

local function CheckOrphans()
	orphanCheck = false
	if running and pending > 0 then Bump(data, "AddMessage outside OnEvent", pending) end
	pending = 0
end

local function HookBlizzard()
	if hookedBlizzard or not CombatText then return end
	hookedBlizzard = true
	hooksecurefunc(CombatText, "AddMessage", function()
		if not running then return end
		pending = pending + 1
		if not orphanCheck then
			orphanCheck = true
			C_Timer.After(0, CheckOrphans)
		end
	end)
	CombatText:HookScript("OnEvent", function(_, event, arg1)
		if not running then
			pending = 0
			return
		end
		local key = event
		if event == "COMBAT_TEXT_UPDATE" then
			key = event .. " " .. ((not IsSecret(arg1) and type(arg1) == "string") and arg1 or "<secret type>")
			-- Does GetCurrentEventInfo still give the event's values after Blizzard's handler?
			local ok, n, first = pcall(function() return Count(C_CombatText.GetCurrentEventInfo()) end)
			Bump(Sub(data, "event info in the OnEvent hook"),
				ok and (n .. " values, first " .. (ns.Present(first) and "present" or "nil")) or "error")
		end
		Bump(Sub(Sub(data, "pairing"), key), pending .. " AddMessage")
		pending = 0
	end)
end

EventUtil.ContinueOnAddOnLoaded("Blizzard_CombatText", HookBlizzard)

-- The game's settings (check 18) --------------------------------------------------------------------------------------

local function TestSetCVar()
	local where = Context()
	local results = Sub(data, "SetCVar")
	if results[where] then return end
	local current = C_CVar.GetCVar(SETCVAR_TEST)
	if current == nil then
		results[where] = "no such setting"
		return
	end
	local ok, result = pcall(C_CVar.SetCVar, SETCVAR_TEST, current)
	results[where] = ok and ("returned " .. Text(result)) or ("error: " .. ErrorText(result))
end

-- Combat log (checks 6-8) ---------------------------------------------------------------------------------------------

local function CheckCombatLogRestricted()
	Bump(Sub(data, "IsCombatLogRestricted"), Context() .. " " .. Try(C_CombatLog and C_CombatLog.IsCombatLogRestricted))
end

local function OnCombatLogMessage(text, r, g, b)
	local rec = Sub(data, "COMBAT_LOG_MESSAGE")
	local where = Context()
	Bump(rec, where)
	Bump(rec, where .. " text " .. Kind(text))
	Bump(rec, where .. " colour " .. Kind(r) .. "/" .. Kind(g) .. "/" .. Kind(b))
	local loaded = C_AddOns.IsAddOnLoaded("Blizzard_CombatLog")
	Bump(rec, "with Blizzard_CombatLog " .. (loaded and "loaded" or "not loaded"))
end

-- Cooldowns (checks 10, 12, 14) ---------------------------------------------------------------------------------------
-- Each followed spell is on cooldown once SPELL_UPDATE_COOLDOWN shows it active beyond the global cooldown, and ends
-- when isActive turns false: seen in the event itself, or by the 0.1 s check between events (then the time until the
-- next event is noted).

local tracked = {}              -- spellID -> { onCooldown }
local trackedCount = 0
local waiting = {}              -- ends seen between events, waiting for the next event
local lastCooldownEvent = 0

local function Track(spellID)
	if IsSecret(spellID) or type(spellID) ~= "number" or tracked[spellID] or trackedCount >= MAX_TRACKED then return end
	tracked[spellID] = { onCooldown = false }
	trackedCount = trackedCount + 1
end

local function LogEnd(spellID, seenIn)
	local now = GetTime()
	local entry = { spell = spellID, at = now, seenIn = seenIn, context = Context() }
	if seenIn == "check" then
		entry.sinceEvent = now - lastCooldownEvent
		waiting[#waiting + 1] = entry
	end
	Bump(Sub(data, "cooldown ends"), entry.context .. " seen in " .. seenIn)
	local log = Sub(data, "cooldownLog")
	if #log < MAX_LOG then log[#log + 1] = entry end
end

local function CheckCooldown(spellID, state, inEvent)
	local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
	if not ok or IsSecret(info) or type(info) ~= "table" then return end
	local active, onGCD = info.isActive, info.isOnGCD
	if IsSecret(active) or IsSecret(onGCD) then
		Bump(data, "isActive or isOnGCD secret")
		return
	end
	if state.onCooldown then
		if not active or (inEvent and onGCD == true) then
			state.onCooldown = false
			LogEnd(spellID, inEvent and "event" or "check")
		end
	elseif active and inEvent and onGCD == false then
		state.onCooldown = true
	end
end

local function OnSpellUpdateCooldown(spellID)
	local now = GetTime()
	lastCooldownEvent = now
	local payload = spellID == nil and "nil spellID" or (Kind(spellID) .. " spellID")
	Bump(Sub(data, "SPELL_UPDATE_COOLDOWN"), Context() .. " " .. payload)
	for _, entry in ipairs(waiting) do
		entry.nextEvent = now - entry.at
	end
	wipe(waiting)
	for id, state in pairs(tracked) do
		CheckCooldown(id, state, true)
	end
end

-- The Cooldown Manager's items as Blizzard has them now (read only).
local VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer" }
local function ManagerItems()
	local list = {}
	for _, viewerName in ipairs(VIEWERS) do
		local viewer = _G[viewerName]
		local ok, items = false, nil
		if viewer and viewer.GetItemFrames then ok, items = pcall(viewer.GetItemFrames, viewer) end
		if not ok or type(items) ~= "table" then
			list[#list + 1] = { viewer = viewerName, missing = true }
		else
			for _, item in ipairs(items) do
				local function Call(method)
					local okCall, value = pcall(function() return item[method](item) end)
					if okCall then return value end
					return nil
				end
				list[#list + 1] = {
					viewer = viewerName, cooldownID = Call("GetCooldownID"), info = Call("GetCooldownInfo"),
					baseSpellID = Call("GetBaseSpellID"),
				}
			end
		end
	end
	return list
end

local function TrackManagerSpells()
	for _, entry in ipairs(ManagerItems()) do
		local info = entry.info
		if type(info) == "table" and not IsSecret(info) then
			Track(info.overrideSpellID)
			Track(info.spellID)
		end
	end
end

local hookedAlerts = false
local function HookAlerts()
	if hookedAlerts or type(CooldownViewerAlert_PlayAlert) ~= "function" then return end
	hookedAlerts = true
	hooksecurefunc("CooldownViewerAlert_PlayAlert", function(item, spellName)
		if not running then return end
		local rec = Sub(data, "Cooldown Manager alerts")
		local where = Context()
		local ok, id = pcall(function() return item:GetCooldownID() end)
		Bump(rec, where .. " cooldownID " .. (ok and Kind(id) or "error") .. ", name " .. Kind(spellName))
	end)
end

EventUtil.ContinueOnAddOnLoaded("Blizzard_CooldownViewer", HookAlerts)

-- Usable abilities and Clearcasting (checks 15, 17) -------------------------------------------------------------------
-- Noted when what the game says changes, so the counts read as "became usable 3 times in combat".

local function UsableSpells()
	local spells = {}
	local _, class = UnitClass("player")
	for _, trigger in ipairs(ns.BUILTIN_TRIGGERS or {}) do
		if trigger.kind == "usable" and tContains(trigger.classes or {}, class) then
			for _, id in ipairs(trigger.spells or {}) do spells[#spells + 1] = id end
		end
	end
	local custom = ns.profile and ns.profile.triggers and ns.profile.triggers.custom
	for _, trigger in ipairs(type(custom) == "table" and custom or {}) do
		if trigger.kind == "usable" and type(trigger.spell) == "number" then spells[#spells + 1] = trigger.spell end
	end
	return spells
end

local lastUsable, lastAura = {}, {}

local function Note(category, last, id, outcome)
	if last[id] == outcome then return end
	last[id] = outcome
	Bump(Sub(Sub(data, category), tostring(id)), Context() .. " " .. outcome)
end

local usableAt = 0
local function CheckUsable(force)
	local now = GetTime()
	if not force and now - usableAt < THROTTLE then return end
	usableAt = now
	for _, id in ipairs(UsableSpells()) do
		local ok, usable, noPower = pcall(C_Spell.IsSpellUsable, id)
		local outcome
		if not ok then
			outcome = "error"
		elseif IsSecret(usable) or IsSecret(noPower) then
			outcome = "secret"
		elseif usable then
			outcome = "usable"
		elseif noPower then
			outcome = "short of power"
		else
			outcome = "not usable"
		end
		Note("IsSpellUsable", lastUsable, id, outcome)
	end
end

local auraAt = 0
local function CheckAuras(force)
	local now = GetTime()
	if not force and now - auraAt < THROTTLE then return end
	auraAt = now
	for _, id in ipairs(CLEARCASTING) do
		local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
		local outcome
		if not ok then
			outcome = "error"
		elseif IsSecret(aura) then
			outcome = "secret"
		elseif aura == nil then
			outcome = "not up"
		else
			outcome = "up" .. (IsSecret(aura.duration) and " (duration secret)" or "")
		end
		Note("GetPlayerAuraBySpellID", lastAura, id, outcome)
	end
end

-- Recording -----------------------------------------------------------------------------------------------------------

local handlers = {
	COMBAT_TEXT_UPDATE = OnCombatTextUpdate,
	COMBAT_LOG_MESSAGE = OnCombatLogMessage,
	SPELL_UPDATE_COOLDOWN = OnSpellUpdateCooldown,
	SPELL_UPDATE_USABLE = function() CheckUsable() end,
	ACTIONBAR_UPDATE_USABLE = function() CheckUsable() end,
	UNIT_AURA = function() CheckAuras() end,
	UNIT_SPELLCAST_SUCCEEDED = function(_, _, spellID) Track(spellID) end,
	PLAYER_REGEN_DISABLED = function()
		TestSetCVar()
		CheckCombatLogRestricted()
		CheckUsable(true)
		CheckAuras(true)
	end,
	PLAYER_REGEN_ENABLED = function()
		CheckCombatLogRestricted()
		CheckUsable(true)
		CheckAuras(true)
	end,
	PLAYER_ENTERING_WORLD = function() CheckCombatLogRestricted() end,
	ZONE_CHANGED_NEW_AREA = function() CheckCombatLogRestricted() end,
	ADDON_ACTION_BLOCKED = function(addon, action)
		Bump(Sub(data, "blocked actions"), Context() .. " " .. Text(addon) .. " " .. Text(action))
	end,
	ADDON_ACTION_FORBIDDEN = function(addon, action)
		Bump(Sub(data, "forbidden actions"), Context() .. " " .. Text(addon) .. " " .. Text(action))
	end,
	COOLDOWN_VIEWER_DATA_LOADED = TrackManagerSpells,
}

frame:SetScript("OnEvent", function(_, event, ...)
	if not running then return end
	local handler = handlers[event]
	if handler then ns.SafeCall("Probe " .. event, handler, ...) end
end)

local function Tick()
	if not running then return end
	local now = GetTime()
	for id, state in pairs(tracked) do
		if state.onCooldown then CheckCooldown(id, state, false) end
	end
	for i = #waiting, 1, -1 do
		if now - waiting[i].at > NEXT_EVENT_WAIT then
			waiting[i].nextEvent = "none within " .. NEXT_EVENT_WAIT .. " s"
			table.remove(waiting, i)
		end
	end
	if ns.InCombat() then CheckUsable() end
end

local function Register(event, unit)
	local ok, err
	if unit then
		ok, err = pcall(frame.RegisterUnitEvent, frame, event, unit)
	else
		ok, err = pcall(frame.RegisterEvent, frame, event)
	end
	Sub(data, "registering")[event] = ok and "registered" or ("error: " .. ErrorText(err))
end

local function StartRecording()
	running = true
	for _, event in ipairs(EVENTS) do Register(event) end
	for _, event in ipairs(UNIT_EVENTS) do Register(event, "player") end
	HookBlizzard()
	HookAlerts()
	TrackManagerSpells()
	if not ns.InCombat() then TestSetCVar() end
	CheckCombatLogRestricted()
	CheckUsable(true)
	CheckAuras(true)
	if not ticker then ticker = C_Timer.NewTicker(POLL, Tick) end
end

local function StopRecording()
	running = false
	frame:UnregisterAllEvents()
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
end

-- Showing -------------------------------------------------------------------------------------------------------------

local copyBox
local function ShowCopyBox(title, text)
	if not copyBox then
		copyBox = CreateFrame("Frame", "CombatTextExtendedProbe", UIParent, "PortraitFrameTemplate")
		copyBox:SetSize(620, 480)
		copyBox:SetPoint("CENTER")
		copyBox:SetFrameStrata("DIALOG")
		copyBox:SetMovable(true)
		copyBox:EnableMouse(true)
		copyBox:RegisterForDrag("LeftButton")
		copyBox:SetScript("OnDragStart", copyBox.StartMoving)
		copyBox:SetScript("OnDragStop", copyBox.StopMovingOrSizing)
		copyBox:SetPortraitToAsset("Interface\\Icons\\Spell_Holy_InnerFire")
		table.insert(UISpecialFrames, "CombatTextExtendedProbe")
		local scroll = CreateFrame("ScrollFrame", nil, copyBox, "ScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 16, -64)
		scroll:SetPoint("BOTTOMRIGHT", -30, 16)
		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		edit:SetAutoFocus(false)
		edit:SetFontObject("ChatFontNormal")
		edit:SetWidth(560)
		edit:SetScript("OnEscapePressed", function() copyBox:Hide() end)
		scroll:SetScrollChild(edit)
		copyBox.edit = edit
		local hint = copyBox:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", 64, -38)
		hint:SetText("Ctrl+A then Ctrl+C to copy.")
	end
	copyBox:SetTitle(title)
	copyBox.edit:SetText(text)
	copyBox:Show()
	copyBox.edit:SetFocus()
	copyBox.edit:HighlightText()
end

-- "key count, key count" for a table of counts, sorted.
local function Counts(tbl)
	local parts = {}
	for key, value in pairs(tbl or {}) do
		if type(value) ~= "table" then parts[#parts + 1] = tostring(key) .. " " .. tostring(value) end
	end
	table.sort(parts)
	return #parts > 0 and table.concat(parts, ", ") or "nothing yet"
end

local function SortedKeys(tbl)
	local keys = {}
	for key in pairs(tbl or {}) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function Seconds(value)
	if type(value) == "number" then return ("%.2f s"):format(value) end
	return tostring(value or "waiting")
end

local function Report()
	local found = ns.global and ns.global.probe or {}
	local lines = {}
	local function Add(text) lines[#lines + 1] = text end
	local function Section(title) Add("") Add("== " .. title .. " ==") end

	Add("Combat Text Extended probe, " .. date("%Y-%m-%d %H:%M"))
	Add("Client: " .. Try(GetBuildInfo))
	Add("Recording: " .. (running and "on" or "off") .. (found.started and (", since " .. found.started) or ""))
	Add("Now: " .. Context() .. ", game's combat text " .. (ns.GameSetting("enableFloatingCombatText") and "on" or "off"))

	Section("Combat text feed (beta checks 1-3)")
	local feed = found.feed or {}
	if not next(feed) then Add("No COMBAT_TEXT_UPDATE yet.") end
	for _, messageType in ipairs(SortedKeys(feed)) do
		local rec = feed[messageType]
		Add(messageType .. ": " .. Counts(rec))
		for _, key in ipairs(SortedKeys(rec)) do
			if type(rec[key]) == "table" then Add("  " .. key .. ": " .. Counts(rec[key])) end
		end
	end

	Section("Secret values (beta checks 4, 5)")
	local ops = found.secretOps or {}
	for _, kind in ipairs({ "string", "number" }) do
		local result = ops[kind]
		if result then
			Add("Secret " .. kind .. " (" .. tostring(result.context) .. "):")
			for _, op in ipairs(OPS) do Add("  " .. op[1] .. ": " .. tostring(result[op[1]])) end
			Add("  width after SetText: " .. tostring(result.width))
		else
			Add("No secret " .. kind .. " seen yet.")
		end
	end

	Section("Blizzard's frame (beta checks 11, 16)")
	Add("Blizzard_CombatText loaded: " .. tostring(C_AddOns.IsAddOnLoaded("Blizzard_CombatText")))
	if CombatText then Add("CombatText alpha: " .. Try(CombatText.GetAlpha, CombatText) ..
		", visible: " .. Try(CombatText.IsVisible, CombatText)) end
	for _, key in ipairs(SortedKeys(found.pairing)) do Add(key .. ": " .. Counts(found.pairing[key])) end
	Add("AddMessage outside OnEvent: " .. tostring(found["AddMessage outside OnEvent"] or 0))
	Add("GetCurrentEventInfo in the OnEvent hook: " .. Counts(found["event info in the OnEvent hook"]))

	Section("The game's settings (beta check 18)")
	for _, cvar in ipairs(CVARS) do
		Add(cvar .. " = " .. Try(C_CVar.GetCVar, cvar) .. " (default " .. Try(C_CVar.GetCVarDefault, cvar) .. ")")
	end
	Add("SetCVar(" .. SETCVAR_TEST .. ", its own value): " .. Counts(found.SetCVar))
	Add("Blocked actions: " .. Counts(found["blocked actions"]))
	Add("Forbidden actions: " .. Counts(found["forbidden actions"]))
	Add("Registering events: " .. Counts(found.registering))

	Section("Combat log (beta checks 6-8)")
	Add("COMBAT_LOG_MESSAGE: " .. Counts(found.COMBAT_LOG_MESSAGE))
	Add("IsCombatLogRestricted: " .. Counts(found.IsCombatLogRestricted))
	Add("Blizzard_CombatLog loaded now: " .. tostring(C_AddOns.IsAddOnLoaded("Blizzard_CombatLog")))

	Section("Cooldowns (beta checks 10, 12, 14)")
	for _, entry in ipairs(ManagerItems()) do
		if entry.missing then
			Add(entry.viewer .. ": no items")
		else
			local info = entry.info
			local spell = type(info) == "table" and not IsSecret(info) and (info.overrideSpellID or info.spellID)
			Add(entry.viewer .. ": cooldownID " .. Text(entry.cooldownID) .. ", base spell " .. Text(entry.baseSpellID) ..
				(spell and (" (" .. SpellName(spell) .. ")") or "") .. ", info " .. Text(info))
		end
	end
	Add("Spells followed this session: " .. trackedCount)
	Add("SPELL_UPDATE_COOLDOWN: " .. Counts(found.SPELL_UPDATE_COOLDOWN))
	Add("Cooldown ends: " .. Counts(found["cooldown ends"]))
	if found["isActive or isOnGCD secret"] then Add("isActive or isOnGCD secret: " .. found["isActive or isOnGCD secret"]) end
	for _, entry in ipairs(found.cooldownLog or {}) do
		local text = ("  %s (%d) at %.2f, %s, seen in %s"):format(SpellName(entry.spell), entry.spell, entry.at,
			tostring(entry.context), tostring(entry.seenIn))
		if entry.seenIn == "check" then
			text = text .. ", " .. Seconds(entry.sinceEvent) .. " after the last event, next event " ..
				Seconds(entry.nextEvent)
		end
		Add(text)
	end
	Add("Cooldown Manager alerts: " .. Counts(found["Cooldown Manager alerts"]))

	Section("Usable abilities (beta check 15)")
	local usable = found.IsSpellUsable or {}
	if not next(usable) then Add("No trigger spells for this class.") end
	for _, id in ipairs(SortedKeys(usable)) do
		Add(SpellName(tonumber(id)) .. " (" .. id .. "): " .. Counts(usable[id]))
	end

	Section("Clearcasting (beta check 17)")
	for _, id in ipairs(CLEARCASTING) do
		Add(SpellName(id) .. " (" .. id .. "): GetSpellAuraSecrecy " ..
			Try(C_Secrets and C_Secrets.GetSpellAuraSecrecy, id) .. "; " ..
			Counts((found.GetPlayerAuraBySpellID or {})[tostring(id)]))
	end

	Section("Atlases")
	for _, atlas in ipairs(ATLASES) do
		Add(atlas .. ": " .. Try(C_Texture.GetAtlasInfo, atlas))
	end
	return table.concat(lines, "\n")
end

-- Commands ------------------------------------------------------------------------------------------------------------

local USAGE = "/ctx probe start | stop | show"

function Probe.Run(args)
	local action = args and args[2] and args[2]:lower()
	if not ns.global then return end
	if action == "start" then
		StopRecording()
		ns.global.probe = { running = true, started = date("%Y-%m-%d %H:%M") }
		data = ns.global.probe
		wipe(tracked)
		trackedCount = 0
		wipe(waiting)
		wipe(lastUsable)
		wipe(lastAura)
		StartRecording()
		ns.Print("Probe recording. Play in and out of combat and in an instance, use spells with cooldowns, then " ..
			"/ctx probe show.")
	elseif action == "stop" then
		StopRecording()
		if ns.global.probe then ns.global.probe.running = false end
		ns.Print("Probe stopped. Its findings are kept until the next start.")
	elseif action == "show" then
		ShowCopyBox("Combat Text Extended probe", Report())
	else
		ns.Print(USAGE)
	end
end

-- Recording carries on after a reload or relog until it's stopped.
ns.Listen("LOGIN", function()
	local saved = ns.global and ns.global.probe
	if type(saved) == "table" and saved.running then
		data = saved
		StartRecording()
	end
end)
