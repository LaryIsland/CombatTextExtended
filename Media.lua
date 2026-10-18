local addonName, ns = ...
local L = ns.L

-- Fonts and sounds to pick from (design document 4.7): the game's own, plus anything other addons share through
-- LibSharedMedia-3.0, which is optional. Saved settings hold a font or sound by its value here: false for the game's
-- font or no sound, a LibSharedMedia name, or for the game's own sounds "game:" and the sound kit's SOUNDKIT name (a
-- name rather than the number, so it reads in saved data and can't clash with a shared sound's name).
--   ns.Media.Fonts()            { { value, text }, ... } for a dropdown, the game's font first
--   ns.Media.FontPath(value)    the font file to use for a value
--   ns.Media.Sounds()           { { value, text }, ... } for a dropdown, none first, then the game's, then shared ones
--   ns.Media.Play(value, force) plays a sound on the Master channel, unless sounds are off (force: play anyway, for
--                               hearing a sound as it's picked)
--   ns.Media.Has(kind, value)   whether a value can be used now ("font" or "sound"; false always can)

local Media = {}
ns.Media = Media

local media = LibStub("LibSharedMedia-3.0", true)

-- Fonts --------------------------------------------------------------------------------------------------------------

-- The game's combat text font, which has the right file for the client's alphabet (SystemFont_World). STANDARD_TEXT_FONT
-- only if that font object is somehow missing.
local function GameFontPath()
	local object = _G.CombatTextFont
	local path = object and object.GetFont and object:GetFont()
	return path or STANDARD_TEXT_FONT
end

function Media.Fonts()
	local list = { { value = false, text = L.FONT_GAME } }
	if media then
		for _, name in ipairs(media:List(media.MediaType.FONT) or {}) do
			list[#list + 1] = { value = name, text = name }
		end
	end
	return list
end

-- A shared font whose addon has gone falls back to the game's, so text never goes blank.
function Media.FontPath(value)
	if type(value) == "string" and media then
		local path = media:Fetch(media.MediaType.FONT, value, true)
		if path then return path end
	end
	return GameFontPath()
end

-- Sounds -------------------------------------------------------------------------------------------------------------

-- A few of the game's own alert sounds, by their SOUNDKIT names (Blizzard_SharedXML/Mainline/SoundKitConstants.lua).
local GAME_SOUNDS = {
	{ kit = "RAID_WARNING", text = L.SOUND_RAID_WARNING },
	{ kit = "READY_CHECK", text = L.SOUND_READY_CHECK },
	{ kit = "ALARM_CLOCK_WARNING_3", text = L.SOUND_ALARM_CLOCK },
	{ kit = "UI_RAID_BOSS_WHISPER_WARNING", text = L.SOUND_BOSS_WHISPER },
	{ kit = "TELL_MESSAGE", text = L.SOUND_WHISPER },
	{ kit = "MAP_PING", text = L.SOUND_MAP_PING },
}
local GAME_PREFIX = "game:"
-- Played when a shared sound's addon has gone, so the alert isn't lost (as Pitiful Loot does).
local FALLBACK_KIT = "RAID_WARNING"

-- The sound kit number for a "game:" value, or nil.
local function GameKit(value)
	if type(value) ~= "string" or value:sub(1, #GAME_PREFIX) ~= GAME_PREFIX then return nil end
	local kit = SOUNDKIT and SOUNDKIT[value:sub(#GAME_PREFIX + 1)]
	return type(kit) == "number" and kit or nil
end

function Media.Sounds()
	local list = { { value = false, text = L.SOUND_NONE } }
	for _, sound in ipairs(GAME_SOUNDS) do
		if SOUNDKIT and SOUNDKIT[sound.kit] then
			list[#list + 1] = { value = GAME_PREFIX .. sound.kit, text = sound.text }
		end
	end
	-- LibSharedMedia has a "None" of its own, which is left out for ours.
	if media then
		for _, name in ipairs(media:List(media.MediaType.SOUND) or {}) do
			if name ~= "None" then list[#list + 1] = { value = name, text = name } end
		end
	end
	return list
end

-- On the Master channel, so it's heard with the game's sound effects turned off.
function Media.Play(value, force)
	if not value then return end
	if not force and not (ns.profile and ns.profile.sounds) then return end
	local kit = GameKit(value)
	if kit then
		PlaySound(kit, "Master")
		return
	end
	local file = type(value) == "string" and media and media:Fetch(media.MediaType.SOUND, value, true)
	if file then
		PlaySoundFile(file, "Master")
	elseif SOUNDKIT and SOUNDKIT[FALLBACK_KIT] then
		PlaySound(SOUNDKIT[FALLBACK_KIT], "Master")
	end
end

-- Whether a font or sound value can be used as it is now: false (the game's font, no sound) always can; a shared one
-- only while its addon has registered it. Presets use this to pick MSBT's font and sounds only when they're there.
function Media.Has(kind, value)
	if value == false or value == nil then return true end
	if kind == "sound" and GameKit(value) then return true end
	if type(value) ~= "string" or not media then return false end
	local mediaType = kind == "font" and media.MediaType.FONT or media.MediaType.SOUND
	return media:IsValid(mediaType, value) == true
end
