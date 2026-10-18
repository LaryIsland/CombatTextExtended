local addonName, ns = ...
local L = ns.L

-- Blizzard's own combat text frame (design document 2.1, 4.5). CTX shows Blizzard's finished messages, so its frame
-- keeps running: invisible (alpha 0) while CTX is on, never hidden, as a hidden frame stops handling events. Two
-- post-hooks take the messages: AddMessage collects each one, and OnEvent, which runs after Blizzard's handler, pairs
-- them with the event (and so the message type) that made them and hands them to the router.
--
-- Nothing here writes a field on CombatText or Blizzard's tables: Blizzard's handler compares secret health and
-- power, which only works while its own execution is untainted. Post-hooks only.

local Blizzard = {}
ns.Blizzard = Blizzard

local BLIZZARD_ADDON = "Blizzard_CombatText"
local SETTING = "enableFloatingCombatText"      -- the game's "Scrolling Combat Text for Self"
local PROMPT = "COMBATTEXTEXTENDED_TURN_ON"
local SNOOZE = 7 * 24 * 60 * 60                 -- "Not now" asks again after a week

local hooked = false

function Blizzard.IsLoaded()
	return hooked
end

-- Alpha ---------------------------------------------------------------------------------------------------------------
-- Blizzard only sets the alpha of its font strings, never of the frame, so the frame's alpha hides every line while
-- its events and OnUpdate keep running. The SetAlpha post-hook puts it back to 0 if anything else changes it.

local hidden = false       -- what CTX wants: Blizzard's frame at alpha 0
local settingAlpha = false -- our own SetAlpha call, so the post-hook doesn't answer it

local function WantHidden()
	local profile = ns.profile
	if not profile then return false end
	if ns.Router and ns.Router.Active then
		return ns.Router.Active() == true
	end
	return profile.enabled == true and ns.GameSetting(SETTING)
end

local function SetFrameAlpha(alpha)
	settingAlpha = true
	CombatText:SetAlpha(alpha)
	settingAlpha = false
end

-- Alpha 1 is only given back when CTX had taken it away, so an alpha some other addon set isn't overwritten.
function Blizzard.ApplyAlpha()
	if not hooked then return end
	if WantHidden() then
		hidden = true
		SetFrameAlpha(0)
	elseif hidden then
		hidden = false
		SetFrameAlpha(1)
	end
end

local function OnSetAlpha()
	-- The alpha passed in isn't looked at (it could be anything, even secret): while hidden it's always put back.
	if hidden and not settingAlpha then
		SetFrameAlpha(0)
	end
end

-- Messages ------------------------------------------------------------------------------------------------------------
-- Blizzard's OnEvent makes at most one message and calls AddMessage as its last step (CombatText.lua:291-294), so
-- when the OnEvent post-hook runs, the last message AddMessage saw is the one that event made. A hook can't run
-- before Blizzard's handler, so anything collected earlier is stale (AddMessage called by another addon): each
-- message replaces the one before, and the OnUpdate post-hook drops what's left at the end of every frame. The
-- values may be secret: they're only kept and passed on, and let go of straight after.

local waiting = false
local pMessage, pR, pG, pB, pDisplayType, pStaggered

local function OnAddMessage(_, message, _, r, g, b, displayType, isStaggered)
	pMessage, pR, pG, pB, pDisplayType, pStaggered = message, r, g, b, displayType, isStaggered
	waiting = true
end

local function Forget()
	waiting = false
	pMessage, pR, pG, pB, pDisplayType, pStaggered = nil, nil, nil, nil, nil, nil
end

-- The message types Blizzard's frame makes itself from events other than COMBAT_TEXT_UPDATE (CombatText.lua:61-107).
-- The others it handles (vehicles; Plunderstorm's CURRENCY_DISPLAY_UPDATE) make nothing CTX shows.
local MADE_BY_BLIZZARD = {
	UNIT_HEALTH = "HEALTH_LOW",
	PLAYER_REGEN_DISABLED = "ENTERING_COMBAT",
	PLAYER_REGEN_ENABLED = "LEAVING_COMBAT",
	RUNE_POWER_UPDATE = "RUNE",
}

-- The message type for an event Blizzard's frame handled, or nil for events CTX doesn't show and for a type the
-- client hides.
local function FeedType(event, arg1, arg2)
	if event == "COMBAT_TEXT_UPDATE" then
		if ns.IsSecret(arg1) or type(arg1) ~= "string" then return nil end
		return arg1
	elseif event == "UNIT_POWER_UPDATE" then
		-- Low mana; or combo points, where Blizzard makes those from this event (Classic's CombatTextUtil. Forever's
		-- Mainline override makes nothing, CombatTextUtilOverrides.lua:1-4).
		if ns.Readable(arg2) == "COMBO_POINTS" then return "COMBO_POINTS" end
		return "MANA_LOW"
	end
	return MADE_BY_BLIZZARD[event]
end

-- A power gain Blizzard showed as combo points: by its power token when that can be read, else by the colour Blizzard
-- gave it (PowerBarColor.COMBO_POINTS, which no other power gain on Forever uses). Both are only compared.
local function IsComboPoints(token, r, g, b)
	token = ns.Readable(token)
	if type(token) == "string" then return token == "COMBO_POINTS" end
	local color = PowerBarColor and PowerBarColor.COMBO_POINTS
	r, g, b = ns.Readable(r), ns.Readable(g), ns.Readable(b)
	if not (color and type(r) == "number" and type(g) == "number" and type(b) == "number") then return false end
	return math.abs(r - color.r) < 0.01 and math.abs(g - color.g) < 0.01 and math.abs(b - color.b) < 0.01
end

-- The player's combo points, when they can be read, and when they last went up (watched from UNIT_POWER_UPDATE).
local COMBO = Enum and Enum.PowerType and Enum.PowerType.ComboPoints
local COMBO_WINDOW = 0.25 -- a power gain this close to combo points going up is taken as them
local comboCount, comboRoseAt = nil, -math.huge

local function ReadCombo()
	local n = COMBO and UnitPower and ns.Readable(UnitPower("player", COMBO))
	if type(n) == "number" then return n end
	return nil
end

local watcher = CreateFrame("Frame")
watcher:SetScript("OnEvent", function()
	local n = ReadCombo()
	if n and comboCount and n > comboCount then comboRoseAt = GetTime() end
	if n then comboCount = n end
end)
pcall(watcher.RegisterUnitEvent, watcher, "UNIT_POWER_UPDATE", "player")

local function NoBrackets()
	return ns.profile and ns.profile.noBrackets == true
end

-- A power gain whose kind can't be told now (its token hidden), with Remove < > on: a frame later, once the game has
-- counted it in, it's combo points if they've just gone up (passed on with the readable total as its value), else a
-- power gain as it came.
local function RouteLater(router, feedType, message, r, g, b, displayType, isStaggered, data, arg3, arg4, before)
	C_Timer.After(0, function()
		local n = ReadCombo()
		local rose = (n and before and n > before) or (GetTime() - comboRoseAt < COMBO_WINDOW)
		if rose and n then
			ns.SafeCall("Blizzard message", router.FromBlizzard, "COMBO_POINTS", message, r, g, b, displayType,
				isStaggered, n, arg3, arg4)
		else
			ns.SafeCall("Blizzard message", router.FromBlizzard, feedType, message, r, g, b, displayType,
				isStaggered, data, arg3, arg4)
		end
	end)
end

local function OnBlizzardEvent(_, event, arg1, arg2)
	if not waiting then return end
	local message, r, g, b, displayType, isStaggered = pMessage, pR, pG, pB, pDisplayType, pStaggered
	Forget()
	local feedType = FeedType(event, arg1, arg2)
	if not feedType then return end
	local router = ns.Router
	if not (router and router.FromBlizzard) or (router.Active and not router.Active()) then return end
	local data, arg3, arg4
	if event == "COMBAT_TEXT_UPDATE" then
		-- Still the event Blizzard just handled. The values may be secret; they're only passed on.
		data, arg3, arg4 = C_CombatText.GetCurrentEventInfo()
		if feedType == "ENERGIZE" or feedType == "PERIODIC_ENERGIZE" then
			local token = ns.Readable(arg3)
			if type(token) ~= "string" and not IsComboPoints(arg3, r, g, b) and NoBrackets() then
				-- Hidden: which power it was is worked out a frame later (only needed for Remove < >).
				RouteLater(router, feedType, message, r, g, b, displayType, isStaggered, data, arg3, arg4, ReadCombo())
				return
			end
			if token == "COMBO_POINTS" or IsComboPoints(arg3, r, g, b) then
				-- Known: the total is read a frame later too, once the game has counted the gain in.
				RouteLater(router, feedType, message, r, g, b, displayType, isStaggered, data, arg3, arg4, ReadCombo())
				return
			end
		end
	end
	ns.SafeCall("Blizzard message", router.FromBlizzard, feedType, message, r, g, b, displayType, isStaggered,
		data, arg3, arg4)
end

local function OnBlizzardUpdate()
	if waiting then Forget() end
end

-- Hooking --------------------------------------------------------------------------------------------------------------
-- Blizzard_CombatText is load on demand, loaded by Blizzard's settings code when "Scrolling Combat Text for Self" is
-- on or turned on. CTX never loads it itself (a Blizzard addon loaded from addon code risks taint); it waits.

local function Hook()
	if hooked then return end
	local frame = CombatText
	if type(frame) ~= "table" or type(frame.AddMessage) ~= "function" then
		ns.ReportError("Blizzard", BLIZZARD_ADDON .. " loaded without its CombatText frame")
		return
	end
	hooksecurefunc(frame, "AddMessage", OnAddMessage)
	hooksecurefunc(frame, "SetAlpha", OnSetAlpha)
	frame:HookScript("OnEvent", OnBlizzardEvent)
	frame:HookScript("OnUpdate", OnBlizzardUpdate)
	hooked = true
	ns.Fire("BLIZZARD_READY")
end

ns.Listen("DB_READY", function()
	if EventUtil and EventUtil.ContinueOnAddOnLoaded then
		EventUtil.ContinueOnAddOnLoaded(BLIZZARD_ADDON, function()
			ns.SafeCall("Blizzard hook", Hook)
		end)
		return
	end
	-- Without Blizzard's helper: the same thing by hand.
	local _, loaded = C_AddOns.IsAddOnLoaded(BLIZZARD_ADDON)
	if loaded then
		Hook()
		return
	end
	ns.On("ADDON_LOADED", function(name)
		if name == BLIZZARD_ADDON then Hook() end
	end)
end)

ns.Listen("BLIZZARD_READY", Blizzard.ApplyAlpha)
ns.Listen("SETTINGS_CHANGED", Blizzard.ApplyAlpha)
ns.Listen("GAME_SETTING_CHANGED", Blizzard.ApplyAlpha)

-- Asking to turn it on -------------------------------------------------------------------------------------------------
-- CTX shows Blizzard's text, so it needs the game's "Scrolling Combat Text for Self", which is off by default on
-- Forever. Asked once per session at login, with "Not now" waiting a week. Turning it on makes Blizzard's own
-- settings code load Blizzard_CombatText, and the hooks above follow.

StaticPopupDialogs[PROMPT] = {
	text = L.PROMPT_TURN_ON_TEXT, -- %s: the game's own name for the setting
	button1 = L.PROMPT_TURN_ON,
	button2 = L.PROMPT_NOT_NOW,
	OnAccept = function()
		ns.SetGameSetting(SETTING, true)
	end,
	OnCancel = function(_, _, reason)
		-- "clicked" is Not now or Escape; the popup being pushed aside by another doesn't count as an answer.
		if reason == "clicked" then
			ns.global.fctPromptAfter = time() + SNOOZE
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local asked = false

-- Shows the question if the game's setting is off. force: even if it was asked this session or "Not now" is waiting.
function Blizzard.AskToTurnOn(force)
	if ns.GameSetting(SETTING) then return false end
	if not force then
		if asked or time() < (ns.global.fctPromptAfter or 0) then return false end
	end
	asked = true
	StaticPopup_Show(PROMPT, SHOW_COMBAT_TEXT_TEXT)
	return true
end

local waitingForCombatEnd = false

ns.Listen("LOGIN", function()
	if not (ns.profile and ns.profile.enabled) or ns.GameSetting(SETTING) then return end
	if ns.InCombat() then
		waitingForCombatEnd = true
		return
	end
	Blizzard.AskToTurnOn()
end)

ns.Listen("COMBAT", function(inCombat)
	if inCombat or not waitingForCombatEnd then return end
	waitingForCombatEnd = false
	if ns.profile and ns.profile.enabled then
		Blizzard.AskToTurnOn()
	end
end)

-- Turned on some other way (the game's options): the question no longer applies.
ns.Listen("GAME_SETTING_CHANGED", function(cvar)
	if cvar == SETTING and ns.GameSetting(SETTING) then
		StaticPopup_Hide(PROMPT)
	end
end)
