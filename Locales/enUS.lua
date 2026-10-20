local _, ns = ...

-- Every line of text players see, in one place for reviewing and translating. Code uses the names on the left
-- (L.TYPE_DAMAGE); a name with no text here shows as itself, with an error, so a typo is easy to spot.
--
-- This is British English. It's registered as enUS because the game has no English locale but enUS (British clients
-- report enUS too) and AceLocale treats enGB as enUS. A translation goes in a file of its own, loaded after this one
-- in the TOC, that starts:
--   local L = LibStub("AceLocale-3.0"):NewLocale("CombatTextExtended", "deDE")
--   if not L then return end
-- and sets the lines it translates; anything it leaves out stays in English.
--
-- Placeholders: %s is text (a name, a spell, another line), %d a whole number. Keep them, in the same order.
--
-- Names of things in the addon players see or click (options, buttons, pages, commands) go in braces, {like this}:
-- they're shown in a colour of their own. Message templates (the text an event type shows, like +%a XP) never use
-- braces: the ones for CTX's own text are the TEMPLATE_ lines here, and the ones for Blizzard's own messages are
-- built from Blizzard's strings (Catalogue.lua). Players edit their own copies.

local L = LibStub("AceLocale-3.0"):NewLocale("CombatTextExtended", "enUS", true)

-- Event types, groups, presets, fonts and sounds (Catalogue.lua, Presets.lua, Media.lua) -----------------------------

-- Event type groups: the Event Types popup's pages (Catalogue.lua, design document 4.8)
L["GROUP_INCOMING_MELEE"] = "Incoming Melee"
L["GROUP_INCOMING_SPELLS"] = "Incoming Spells"
L["GROUP_HEALING"] = "Healing"
L["GROUP_AURAS"] = "Auras"
L["GROUP_NOTIFICATIONS"] = "Notifications"
-- CTX's own text: cooldowns, loot, money, currency, experience and skill ups.
L["GROUP_CTX"] = "Cooldowns and Loot"

-- Event types: incoming melee (the spell page uses the same words for its misses, blocks and the rest)
L["TYPE_DAMAGE"] = "Damage"
L["TYPE_DAMAGE_CRIT"] = "Crit"
L["TYPE_MISS"] = "Miss"
L["TYPE_DODGE"] = "Dodge"
L["TYPE_PARRY"] = "Parry"
L["TYPE_BLOCK"] = "Block"
L["TYPE_DEFLECT"] = "Deflect"
L["TYPE_ABSORB"] = "Absorb"
L["TYPE_IMMUNE"] = "Immune"
L["TYPE_EVADE"] = "Evade"
L["TYPE_REFLECT"] = "Reflect"
L["TYPE_RESIST"] = "Resist"

-- Event types: incoming spells
L["TYPE_SPELL_DAMAGE"] = "Spell Damage"
L["TYPE_SPELL_DAMAGE_CRIT"] = "Spell Crit"
L["TYPE_DAMAGE_SHIELD"] = "Damage Shield"
L["TYPE_SPELL_MISS"] = "Miss"
L["TYPE_SPELL_DODGE"] = "Dodge"
L["TYPE_SPELL_PARRY"] = "Parry"
L["TYPE_SPELL_BLOCK"] = "Block"
L["TYPE_SPELL_DEFLECT"] = "Deflect"
L["TYPE_SPELL_ABSORB"] = "Absorb"
L["TYPE_SPELL_IMMUNE"] = "Immune"
L["TYPE_SPELL_EVADE"] = "Evade"
L["TYPE_SPELL_REFLECT"] = "Reflect"
L["TYPE_SPELL_RESIST"] = "Resist"

-- Event types: healing
L["TYPE_HEAL"] = "Heal"
L["TYPE_HEAL_CRIT"] = "Heal Crit"
L["TYPE_PERIODIC_HEAL"] = "Heal over Time"
L["TYPE_PERIODIC_HEAL_CRIT"] = "Heal over Time Crit"
L["TYPE_ABSORB_ADDED"] = "Shield Gained"

-- Event types: power, auras, notifications
L["TYPE_ENERGIZE"] = "Power Gain"
L["TYPE_SPELL_AURA_START"] = "Buff"
L["TYPE_SPELL_AURA_START_HARMFUL"] = "Debuff"
L["TYPE_SPELL_AURA_END"] = "Buff Fades"
L["TYPE_SPELL_AURA_END_HARMFUL"] = "Debuff Fades"
-- Blizzard's reactive ability alerts, named as Blizzard's own Text on Me switch for them.
L["TYPE_SPELL_ACTIVE"] = "Spell Alerts"
L["TYPE_SPELL_CAST"] = "Spell Cast"
L["TYPE_FACTION"] = "Reputation"
L["TYPE_HONOR_GAINED"] = "Honour"
L["TYPE_HEALTH_LOW"] = "Low Health"
L["TYPE_MANA_LOW"] = "Low Mana"
L["TYPE_ENTERING_COMBAT"] = "Entering Combat"
L["TYPE_LEAVING_COMBAT"] = "Leaving Combat"

-- Event types: CTX's own
L["TYPE_COOLDOWN"] = "Cooldown Ready"
L["TYPE_LOOT"] = "Loot"
L["TYPE_MONEY"] = "Money"
L["TYPE_CURRENCY"] = "Currency"
L["TYPE_EXPERIENCE"] = "Experience"
L["TYPE_SKILL"] = "Skill Up"
-- The text triggers show (not set up as a type; triggers have their own settings).
L["TYPE_TRIGGER"] = "Triggers"

-- Sample values for previews, Edit Mode and test mode (made up, or plain spell and item names)
L["TYPE_SAMPLE_HEALER"] = "Ana Hollow"
L["TYPE_SAMPLE_BUFF"] = "Power Word: Fortitude"
L["TYPE_SAMPLE_DEBUFF"] = "Curse of Weakness"
L["TYPE_SAMPLE_SPELL_ALERT"] = "Overpower"
L["TYPE_SAMPLE_CAST"] = "Hearthstone"
L["TYPE_SAMPLE_FACTION"] = "Stormwind"
L["TYPE_SAMPLE_COOLDOWN"] = "Shield Wall"
L["TYPE_SAMPLE_ITEM"] = "Linen Cloth"
L["TYPE_SAMPLE_CURRENCY"] = "Badge of Justice"
L["TYPE_SAMPLE_SKILL"] = "First Aid"
L["TYPE_SAMPLE_TRIGGER"] = "Execute"

-- Message templates for CTX's own text (players start from these and edit their own copy). Not format strings: the
-- codes are %a amount, %s spell or skill name, %e item, currency or money, %t total, and %% is a literal %.
L["TEMPLATE_COOLDOWN"] = "<%s> Ready"
L["TEMPLATE_LOOT"] = "+%a %e (%t)"
L["TEMPLATE_MONEY"] = "+%e"
L["TEMPLATE_CURRENCY"] = "+%a %e (%t)"
L["TEMPLATE_EXPERIENCE"] = "+%a XP"
L["TEMPLATE_SKILL"] = "%s: %a"
-- A trigger's text when the player hasn't written one, as MSBT's "Execute!".
L["TEMPLATE_TRIGGER"] = "%s!"

-- Message templates the MSBT preset uses where MSBT has words of its own (MSBT's default profile)
L["TEMPLATE_MSBT_HEALTH_LOW"] = "Low Health!"
L["TEMPLATE_MSBT_MANA_LOW"] = "Low Mana!"
L["TEMPLATE_MSBT_ENTERING_COMBAT"] = "+Combat"
L["TEMPLATE_MSBT_LEAVING_COMBAT"] = "-Combat"
L["TEMPLATE_MSBT_COOLDOWN"] = "%s Ready Now!"

-- Template codes, as the Event Types popup lists them next to a template
L["TEMPLATE_CODE_A"] = "Amount"
L["TEMPLATE_CODE_N"] = "Name of the caster"
L["TEMPLATE_CODE_S"] = "Spell, aura, faction, or skill"
L["TEMPLATE_CODE_P"] = "Power type"
L["TEMPLATE_CODE_R"] = "Amount blocked, absorbed, or resisted"
L["TEMPLATE_CODE_E"] = "Item, currency, or money"
L["TEMPLATE_CODE_T"] = "Total"

-- Kinds of trigger (design document 4.9)
L["TRIGGER_KIND_USABLE"] = "Ability usable"
L["TRIGGER_KIND_AURA"] = "Aura gained"
L["TRIGGER_KIND_COOLDOWN"] = "Cooldown ready"

-- Presets (Options page)
L["PRESET_MSBT"] = "MSBT"
L["PRESET_MSBT_DESC"] = "Mik's Scrolling Battle Text layout."
L["PRESET_LARYISLAND"] = "LaryIsland's Config"
L["PRESET_LARYISLAND_DESC"] = "LaryIsland's own MSBT setup."

-- Area names the presets give (players rename them)
L["AREA_NAME_MAIN"] = "Combat Text"
L["AREA_NAME_INCOMING"] = "Incoming"
L["AREA_NAME_OUTGOING"] = "Outgoing"
L["AREA_NAME_NOTIFICATION"] = "Notification"
L["AREA_NAME_STATIC"] = "Static"

-- Fonts and sounds to pick from (Media.lua)
-- Blizzard's combat text font.
L["FONT_GAME"] = "Game Font"
L["SOUND_NONE"] = "None"
L["SOUND_RAID_WARNING"] = "Raid Warning"
L["SOUND_READY_CHECK"] = "Ready Check"
L["SOUND_ALARM_CLOCK"] = "Alarm Clock"
L["SOUND_BOSS_WHISPER"] = "Boss Whisper"
L["SOUND_WHISPER"] = "Whisper"
L["SOUND_MAP_PING"] = "Map Ping"

-- Areas and animation styles (Areas.lua, Styles.lua) -----------------------------------------------------------------

-- Animation styles (Styles.lua): the names in each area's Animation and Sticky Style dropdowns in Edit Mode
-- Blizzard's own scroll (Up, Down, Arc); also the sticky style that is Blizzard's crit (grow, shrink, stay).
L["STYLE_BLIZZARD"] = "Blizzard"
L["STYLE_ARC"] = "Arc"
L["STYLE_PARABOLA"] = "Parabola"
L["STYLE_ANGLED"] = "Angled"
-- Text that doesn't move; both a normal and a sticky style.
L["STYLE_STATIC"] = "Static"
-- Sticky: appears larger, shrinks to size and holds (MSBT's name).
L["STYLE_POW"] = "Pow"

-- Areas (Areas.lua): the note inside each area in Edit Mode when CTX can't show text
L["AREA_NOTE_OFF"] = "Combat Text Extended is turned off."
-- %s is Blizzard's own name for the setting (SHOW_COMBAT_TEXT_TEXT), as in Options > Gameplay > Combat.
L["AREA_NOTE_SETTING"] = "Turn on Blizzard's {%s} setting to see combat text here."
-- The setting is on but Blizzard's combat text hasn't loaded (it loads when the setting is turned on).
L["AREA_NOTE_NOT_LOADED"] = "Blizzard's combat text hasn't loaded yet. Reload the interface if this stays."
-- Only used if Blizzard's own string (SHOW_COMBAT_TEXT_TEXT) is missing.
L["AREA_SETTING_NAME"] = "Scrolling Combat Text for Self"
-- Name for a new area when none is given (Edit Mode's New Area button gives its own).
L["AREA_DEFAULT_NAME"] = "Combat Text"

-- Asking to turn on Blizzard's combat text (Blizzard.lua) ------------------------------------------------------------

-- Asking to turn on Blizzard's combat text (Blizzard.lua, design document 4.5)
-- A popup at login when Blizzard's "Scrolling Combat Text for Self" is off. %s is Blizzard's own name for that setting
-- (SHOW_COMBAT_TEXT_TEXT), so it matches Options > Gameplay > Combat in every language.
L["PROMPT_TURN_ON_TEXT"] = "Combat Text Extended enhances Blizzard's own combat text, so it needs {%s} to be active.\n\nTurn it on?"
L["PROMPT_TURN_ON"] = "Turn on"
L["PROMPT_NOT_NOW"] = "Not now"

-- Triggers (Triggers.lua) --------------------------------------------------------------------------------------------

-- Triggers (Triggers.lua)
-- A trigger's message when the player hasn't written one: %s is the spell's (or aura's) name.
L["TRIGGERS_MESSAGE"] = "%s"

-- Edit Mode dialogs (EditMode.lua) -----------------------------------------------------------------------------------

-- Edit Mode: area dialog settings (Title Case, as Blizzard's own Edit Mode labels next to them; the label column is
-- 100 px wide, so keep them short). Direction, Text Size, Width and Height are Blizzard's own strings, not in here.
L["EDITMODE_STYLE"] = "Animation"
L["EDITMODE_BEHAVIOUR"] = "Behaviour"
L["EDITMODE_STICKY_STYLE"] = "Sticky Style"
L["EDITMODE_STICKY_BEHAVIOUR"] = "Sticky Effect"
L["EDITMODE_ALIGN"] = "Alignment"
-- Edit Mode's own panel gets a switch of CTX's (as its Damage Meter and the rest have), docked under it.
L["EDITMODE_SHOW_AREAS"] = "Combat Text Areas"
L["EDITMODE_STAGGER"] = "Stagger"
L["EDITMODE_STAGGER_DESC"] = "Damage, miss, dodge, parry, and evade messages\nshift sideways a small amount at random."
L["EDITMODE_ICONS"] = "Icons"
L["EDITMODE_DURATION"] = "Duration"
-- The duration slider's value, in seconds.
L["EDITMODE_SECONDS"] = "%.1fs"

-- Edit Mode: dropdown choices (Up, Down, Left and Right are Blizzard's own strings)
-- Icons: none.
L["EDITMODE_CHOICE_OFF"] = "Off"
L["EDITMODE_CHOICE_ALTERNATE"] = "Alternate"
L["EDITMODE_CHOICE_CENTRE"] = "Centre"
L["EDITMODE_CHOICE_NORMAL"] = "Normal"
L["EDITMODE_CHOICE_JIGGLE"] = "Jiggle"
-- When Busy: what lines do when they come faster than they move away.
L["EDITMODE_OVERFLOW"] = "Overflow"
L["EDITMODE_OVERFLOW_DESC"] = "How simultaneous events are handled.\nMove Aside is Blizzard's default:\nlines stack behind, then to the sides.\n\nPush Along: hurries existing lines to make room.\n\nStack Behind: spawns new lines behind the start."
L["EDITMODE_CHOICE_SHIFT"] = "Move Aside"
L["EDITMODE_CHOICE_PUSH"] = "Push Along"
L["EDITMODE_CHOICE_STACK"] = "Stack Behind"

-- Edit Mode: area dialog buttons
L["EDITMODE_RESET_SETTINGS"] = "Reset Settings"
L["EDITMODE_RESET_POSITION"] = "Reset Position"
L["EDITMODE_EVENT_TYPES"] = "Event Types"
L["EDITMODE_RENAME"] = "Rename Area"
L["EDITMODE_DELETE"] = "Delete Area"
L["EDITMODE_NEW"] = "New Area"
-- Name for a new area; %d is the next free number.
L["EDITMODE_NEW_AREA_NAME"] = "Area %d"

-- Edit Mode: popups (%s is the area's name)
L["EDITMODE_RENAME_PROMPT"] = "Enter a new name for %s"
L["EDITMODE_DELETE_PROMPT"] = "Delete the area %s?"
L["EDITMODE_LAST_AREA"] = "The last area can't be deleted."

-- Edit Mode: fallbacks, only used if Blizzard's own strings (ERR_NOT_IN_COMBAT, ERROR_SLASH_EDITMODE_CANNOT_ENTER) are missing
L["EDITMODE_IN_COMBAT"] = "You can't do that in combat."
L["EDITMODE_CANNOT_ENTER"] = "Edit Mode can't be opened right now."

-- The Event Types popup (EventTypes.lua) -----------------------------------------------------------------------------

-- Laid out like Edit Mode's settings dialogs, so labels are in Title Case as Edit Mode's are.
L["POPUP_TITLE"] = "Event Types"
L["POPUP_PAGE_TRIGGERS"] = "Triggers" -- the last choice in the Group dropdown, after the groups
L["POPUP_GROUP"] = "Group"
L["POPUP_EVENT"] = "Event"
L["POPUP_EVENT_TIP"] = "Click switches, Right-click (or Shift-click) toggle events."
L["POPUP_TRIGGER"] = "Trigger" -- the second dropdown's label on the Triggers page
L["POPUP_SHOW_ALL_CLASSES"] = "Show All Classes"
L["POPUP_NO_TRIGGERS"] = "No triggers for this class yet."
-- Ticking several events sets them up together.
L["POPUP_ALL_EVENTS"] = "All" -- the Event dropdown's first choice, and its text with every event ticked
L["POPUP_EVENTS_COUNT"] = "%d Events" -- the Event dropdown's text with several ticked
L["POPUP_MIXED_TIP"] = "Selected events have different values."
L["POPUP_TEXT_EACH_DEFAULT"] = "Each event's own text" -- grey in the Text box when the ticked events' default texts differ

-- An event's or trigger's settings
L["POPUP_SHOW"] = "Show"
L["POPUP_AREA"] = "Area"
L["POPUP_AREA_SPELL_ALERTS"] = "Spell Alerts' area" -- a trigger's area choice: wherever the Spell Alerts type goes
L["POPUP_TEXT"] = "Text"
-- A block, absorb or resist's grey text: %s the full form ("Block"), %s the partial one ("-%a (%r blocked)").
L["POPUP_TEXT_TWO_FORMS"] = "%s / %s"
L["POPUP_TEXT_TWO_FORMS_TIP"] = "Full / Partial"
L["POPUP_CODES"] = "%s" -- %s: the codes this type can use, "%a Amount, %r Amount blocked..." and so on
L["POPUP_COLOUR"] = "Colour"
L["POPUP_COLOUR_TIP"] = "Right-click for default."
L["POPUP_FONT"] = "Font"
L["POPUP_OUTLINE"] = "Outline"
L["POPUP_DEFAULT"] = "Default" -- the Font and Outline choice that uses what's set on the options page
L["POPUP_FONT_TIP"] = "Default uses the {Combat Text Extended} global setting."
L["POPUP_TEXT_SIZE"] = "Text Size"
L["POPUP_TEXT_SIZE_OFFSET_TIP"] = "Relative to the area's text size."
L["POPUP_STICKY"] = "Sticky"
L["POPUP_STICKY_TIP"] = "Sticky text stays in place, controlled by it's area's {Sticky Style}."
L["POPUP_SOUND"] = "Sound"
L["POPUP_SPELL"] = "Spell"
L["POPUP_SPELL_INPUT"] = "Spell name or ID" -- grey text in the empty spell box
L["POPUP_SPELL_UNKNOWN"] = "No spell found"
L["POPUP_UNKNOWN_SPELL"] = "Spell %d" -- a spell the game has no name for, by its ID

-- An event type Blizzard's own options switch off; followed by where the switch is (POPUP_GAME_SETTING_PATH)
L["POPUP_GAME_SETTING_OFF"] = "Turned off in Blizzard's Combat options:"
L["POPUP_GAME_SETTING_PATH"] = "%s > %s" -- Blizzard's menu, then its switch: "Text on Me > Auras Gained/Lost"

-- Adding and deleting triggers
L["POPUP_ADD_TRIGGER"] = "Add Trigger"
L["POPUP_ADD_TRIGGER_PROMPT"] = "New %s trigger. Type the spell's name or ID:" -- %s: the kind, "Ability usable"
L["POPUP_DELETE_TRIGGER"] = "Delete Trigger"
L["POPUP_DELETE_TRIGGER_PROMPT"] = "Delete the trigger for %s?" -- %s: the spell's name

-- Options, profiles, commands and test mode (Options.lua, Commands.lua, TestMode.lua) --------------------------------

-- Options > AddOns page (Options.lua, design document 4.2) ---------------------------------------------------------
L["OPT_ENABLED"] = "Enabled"
L["OPT_OPEN_EDIT_MODE"] = "Open Edit Mode"
L["OPT_OPEN_EDIT_MODE_TIP"] = "Scrolling Combat Text settings are all configured in Edit Mode."
-- Section headers.
L["OPT_HEADER_STYLE"] = "Style"
L["OPT_HEADER_BLIZZARD"] = "Blizzard Settings"
L["OPT_FONT"] = "Font"
L["OPT_FONT_TIP"] = "Global font for every area."
L["OPT_OUTLINE"] = "Outline"
L["OPT_OUTLINE_TIP"] = "Global outline for every area."
L["OPT_OUTLINE_NONE"] = "None"
L["OPT_OUTLINE_THIN"] = "Thin"
L["OPT_OUTLINE_THICK"] = "Thick"
L["OPT_SHADOW"] = "Shadow"
L["OPT_SHADOW_TIP"] = "Global shadow for every area."
L["OPT_NUMBERS"] = "Numbers"
L["OPT_NUMBERS_TIP"] = "How amounts are written in messages with custom formatting."
-- Number format choices; %s is 12345 written that way.
L["OPT_NUMBERS_FULL"] = "Full (%s)"
L["OPT_NUMBERS_GROUPED"] = "Grouped (%s)"
L["OPT_NUMBERS_SHORT"] = "Short (%s)"
L["OPT_NO_BRACKETS"] = "Remove Angle Brackets < >"
L["OPT_NO_BRACKETS_TIP"] = "Leaves out the < > around names:\n{<Shield Wall>} shows as {Shield Wall}."
L["OPT_ALIGN_ICONS"] = "Include Icons in Alignment"
L["OPT_ALIGN_ICONS_TIP"] = "Lines with an icon take icon width into account when centering."
L["OPT_SOUNDS"] = "Sounds"
L["OPT_SOUNDS_TIP"] = "Global toggle for event sounds."
-- Icon zoom (Style): how the icons beside lines look. Its value shows an example icon.
L["OPT_ICON_ZOOM"] = "Icon Zoom"
L["OPT_ICON_ZOOM_VALUE"] = "%d%%"
-- Refusals, only if Blizzard's own ERR_NOT_IN_COMBAT is missing.
L["OPT_IN_COMBAT"] = "You can't do that in combat."

-- Options page: Blizzard's own combat text settings (design document 4.3). Their labels and tooltips are Blizzard's
-- own strings; the lines below are fallbacks for those, and what CTX adds.
L["OPT_GAME_SETTING_TIP"] = "This is Blizzard's own setting."
-- %s is the setting's name, as Blizzard's options show it.
L["OPT_GAME_SETTING_FAILED"] = "The game didn't let this addon change %s. You can change it in Options > Gameplay > Combat."
-- Fallback for Blizzard's own label (SHOW_COMBAT_TEXT_TEXT), only used if Blizzard's string is missing.
L["OPT_GAME_FCT"] = "Scrolling Combat Text for Self"
-- Fallbacks for Blizzard's own Text on Me and Text on Target dropdowns, only used if its strings are missing.
L["OPT_TEXT_ON_ME"] = "Text on Me"
L["OPT_TEXT_ON_TARGET"] = "Text on Target"
L["OPT_ON"] = "On"
L["OPT_OFF"] = "Off"

-- Options page: cooldowns (design document 4.4)
L["OPT_HEADER_COOLDOWNS"] = "Cooldowns"
L["OPT_COOLDOWN_SOURCE"] = "Spells"
L["OPT_COOLDOWN_SOURCE_TIP"] = "Which spells show {Cooldown ready} when their cooldown ends."
L["OPT_COOLDOWN_SOURCE_CDM"] = "Cooldown Manager's"
L["OPT_COOLDOWN_SOURCE_CDM_TIP"] = "The spells on Blizzard's Cooldown Manager, you pick in its own settings."
L["OPT_COOLDOWN_SOURCE_ALL"] = "Every spell"
L["OPT_COOLDOWN_SOURCE_ALL_TIP"] = "Every spell in your spellbook that has a cooldown."
L["OPT_COOLDOWN_MIN"] = "Shortest cooldown"
L["OPT_COOLDOWN_MIN_TIP"] = "Spells with a shorter cooldown don't show {Cooldown ready}. Only for 'Every spell'."
-- The shortest cooldown slider's value, in whole seconds.
L["OPT_SECONDS"] = "%d s"

-- Options page: presets (design document 1.1, 4.1). The presets' own names and descriptions are PRESET_ lines.
L["OPT_HEADER_PRESETS"] = "Presets"
L["OPT_HEADER_PRESETS_TIP"] = "A premade setup of areas, event types and text style."
L["OPT_PRESET_USE"] = "Use"
-- After the MSBT preset: %s is Blizzard's switches it needs, one per line, in Blizzard's own words.
L["OPT_PRESET_SWITCHES"] = "This preset shows text that Blizzard's combat text settings have off:\n\n%s\n\nTurn them on?"
L["OPT_PRESET_SWITCHES_ON"] = "Turn On"
L["OPT_PRESET_SWITCHES_NOT_NOW"] = "Not Now"
-- %s the preset's name.
L["OPT_PRESET_CONFIRM"] = "Set up the %s preset?\n\nYour areas, event types and text style are replaced."

-- Profiles subpage (Options.lua, design document 4.2) ---------------------------------------------------------------
L["PROFILE_PAGE"] = "Profiles"
L["PROFILE_ACTIVE"] = "Active profile"
L["PROFILE_DEFAULT"] = "Default for new characters"
-- Buttons; the popups they open say what they do.
L["PROFILE_NEW"] = "New Profile"
L["PROFILE_NEW_TEXT"] = "Name the new profile."
L["PROFILE_COPY"] = "Copy from"
-- %s the profile copied from, then the one in use.
L["PROFILE_COPY_CONFIRM"] = "Copy everything from %s into %s?"
-- What the copy from and delete dropdowns show before one is picked.
L["PROFILE_CHOOSE"] = "Choose a profile"
L["PROFILE_DELETE"] = "Delete"
L["PROFILE_DELETE_CONFIRM"] = "Delete the profile %s?"
L["PROFILE_RESET"] = "Reset Profile"
L["PROFILE_RESET_CONFIRM"] = "Reset the profile %s to the default settings?"
L["PROFILE_EXPORT"] = "Export Profile"
L["PROFILE_EXPORT_TEXT"] = "The profile %s as text, to keep or share. Ctrl+C to copy."
L["PROFILE_EXPORT_FAILED"] = "The profile couldn't be turned into text."
L["PROFILE_IMPORT"] = "Import Profile"
L["PROFILE_IMPORT_TEXT"] = "Paste a profile exported from this addon (Ctrl+V):"
L["PROFILE_IMPORT_BAD"] = "That isn't a profile from this addon, or part of it is missing."
L["PROFILE_IMPORT_NAME_TEXT"] = "Name the imported profile:"
L["PROFILE_EXISTS"] = "There's already a profile called %s."
-- Importing Mik's Scrolling Battle Text's profiles (MSBTImport.lua): the row's name, its button and its tooltip.
L["PROFILE_MSBT"] = "Mik's Scrolling Battle Text"
L["PROFILE_MSBT_IMPORT"] = "Import Profiles"
L["PROFILE_MSBT_TIP"] = "Paste MSBT's saved settings."
-- The window the saved settings are pasted into: its title and what to paste.
L["PROFILE_MSBT_PASTE_TITLE"] = "Import from MSBT"
L["PROFILE_MSBT_PASTE_TEXT"] = "Paste the contents of MikScrollingBattleText.lua from your WTF\\Account\\<account>\\SavedVariables folder."
L["PROFILE_MSBT_BAD"] = "That isn't an MSBT saved settings file, or it has no profiles in it."
-- %s MSBT's profiles, one per line.
L["PROFILE_MSBT_CONFIRM"] = "Import these profiles from Mik's Scrolling Battle Text?\n\n%s"
-- %s the new profiles' names.
L["PROFILE_MSBT_DONE"] = "Imported from MSBT: %s"
-- The imported profiles' names: MSBT's Default profile, then any other (%s its name in MSBT).
L["PROFILE_MSBT_NAME"] = "MSBT Import"
L["PROFILE_MSBT_NAME_OF"] = "MSBT Import (%s)"

-- /ctx help (Commands.lua, design document 4.2)
L["HELP_OPTIONS"] = "{/ctx} - options page and profiles"
L["HELP_TYPES"] = "{/ctx types} - event types and triggers"
L["HELP_TEST"] = "{/ctx test} - test combat text events"
L["HELP_HELP"] = "{/ctx help} - this list"

-- Test mode (TestMode.lua)
L["TEST_ON"] = "Test mode on."
L["TEST_OFF"] = "Test mode off."
L["TEST_DISABLED"] = "Test mode needs {Enabled} on in the options."
-- %s is Blizzard's own name for the setting (SHOW_COMBAT_TEXT_TEXT), so it matches its Combat options.
L["TEST_NOT_READY"] = "Test mode needs Blizzard's \"%s\" setting on."
-- Fallback for that name, only used if Blizzard's string is missing.
L["TEST_GAME_SETTING"] = "Scrolling Combat Text for Self"
L["TEST_NOTHING_ON"] = "Every event type is off in Blizzard's Combat options. Turn some on in {Event Types}."

ns.L = LibStub("AceLocale-3.0"):GetLocale("CombatTextExtended")
