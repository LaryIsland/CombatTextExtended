local addonName, ns = ...

-- Loot, money, currency, experience and skill ups (design document 3, 4.8). Blizzard has no combat text for these, so
-- they're read from the chat messages it prints, matched against the game's own global strings (so they follow the
-- client's language), as MSBT does. Chat text can be secret (CHAT_MSG_SKILL in instances, for one); a secret message is
-- skipped before any string function touches it.
--
-- Values given to the router (template codes, Notes/Architecture.md):
--   LOOT        e item link, a amount, t total in bags after this (only when over 1)
--   MONEY       e the money text as the game wrote it
--   CURRENCY    e currency link, a amount, t total (as the currency info says)
--   EXPERIENCE  a amount, n who died (when named)
--   SKILL       s skill name, a new rank

local POOR = Enum and Enum.ItemQuality and Enum.ItemQuality.Poor or 0
local QUEST_ITEM = Enum and Enum.ItemClass and Enum.ItemClass.Questitem or 12

-- Turning global strings into patterns ------------------------------------------------------------------------------------

local MAGIC = "[%^%$%(%)%.%[%]%*%+%-%?]"

-- "You receive loot: %sx%d" -> "^You receive loot: (.+)x(%d+)", with which argument each capture is (positional forms
-- like %1$s can reorder them in other languages).
local function BuildPattern(format)
	local parts, order, count, i = { "^" }, {}, 0, 1
	while i <= #format do
		local c = format:sub(i, i)
		if c == "%" then
			local position, conversion, after = format:match("^%%(%d*)%$?([sd])()", i)
			if conversion then
				count = count + 1
				order[count] = tonumber(position) or count
				parts[#parts + 1] = conversion == "s" and "(.+)" or "(%d+)"
				i = after
			else
				parts[#parts + 1] = "%%"
				i = i + (format:sub(i + 1, i + 1) == "%" and 2 or 1)
			end
		else
			parts[#parts + 1] = c:find(MAGIC) and ("%" .. c) or c
			i = i + 1
		end
	end
	return table.concat(parts), order, count
end

-- Per chat event: the type it shows as, and each global string with the meaning of its arguments in order.
local SOURCES = {
	CHAT_MSG_LOOT = { type = "LOOT", strings = {
		LOOT_ITEM_SELF = { "link" },
		LOOT_ITEM_SELF_MULTIPLE = { "link", "count" },
		LOOT_ITEM_PUSHED_SELF = { "link" },
		LOOT_ITEM_PUSHED_SELF_MULTIPLE = { "link", "count" },
		LOOT_ITEM_CREATED_SELF = { "link" },
		LOOT_ITEM_CREATED_SELF_MULTIPLE = { "link", "count" },
	} },
	CHAT_MSG_MONEY = { type = "MONEY", strings = {
		YOU_LOOT_MONEY = { "money" },
		YOU_LOOT_MONEY_GUILD = { "money", "deposit" },
		YOU_LOOT_MONEY_MOD = { "money", "bonus" },
		LOOT_MONEY_SPLIT = { "money" },
		LOOT_MONEY_SPLIT_GUILD = { "money", "deposit" },
		LOOT_MONEY_SPLIT_MOD = { "money", "bonus" },
	} },
	CHAT_MSG_CURRENCY = { type = "CURRENCY", strings = {
		CURRENCY_GAINED = { "link" },
		CURRENCY_GAINED_MULTIPLE = { "link", "count" },
		CURRENCY_GAINED_MULTIPLE_BONUS = { "link", "count" },
	} },
	CHAT_MSG_COMBAT_XP_GAIN = { type = "EXPERIENCE", strings = {
		COMBATLOG_XPGAIN_FIRSTPERSON = { "name", "amount" },
		COMBATLOG_XPGAIN_FIRSTPERSON_GROUP = { "name", "amount", "bonus" },
		COMBATLOG_XPGAIN_FIRSTPERSON_RAID = { "name", "amount", "penalty" },
		COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED = { "amount" },
		COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP = { "amount", "bonus" },
		COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_RAID = { "amount", "penalty" },
	} },
	CHAT_MSG_SKILL = { type = "SKILL", strings = {
		SKILL_RANK_UP = { "skill", "rank" },
	} },
}

-- Built on first use, when the game's strings are certainly loaded. Most specific first (the most fixed text, then
-- the fewest captures), so "You receive loot: %s" never takes a "...x%d" line.
local patterns = {}
local function Patterns(event)
	local list = patterns[event]
	if list then return list end
	list = {}
	for globalName, fields in pairs(SOURCES[event].strings) do
		local format = _G[globalName]
		if type(format) == "string" and format ~= "" then
			local pattern, order, count = BuildPattern(format)
			local fixed = #(format:gsub("%%%d*%$?[sd]", ""))
			list[#list + 1] = { pattern = pattern, order = order, count = count, fields = fields, fixed = fixed }
		end
	end
	table.sort(list, function(a, b)
		if a.fixed ~= b.fixed then return a.fixed > b.fixed end
		return a.count < b.count
	end)
	patterns[event] = list
	return list
end

-- The message's arguments by meaning ({ link = ..., count = ... }), or nil when no string matches.
local function Parse(event, text)
	for _, entry in ipairs(Patterns(event)) do
		local captures = { text:match(entry.pattern) }
		if captures[1] ~= nil then
			local args = {}
			for k = 1, entry.count do
				local field = entry.fields[entry.order[k]]
				if field then args[field] = captures[k] end
			end
			return args
		end
	end
	return nil
end

-- Showing ------------------------------------------------------------------------------------------------------------------

-- Just the link out of a captured argument, so a full stop or other text another language puts after it is left out.
local function LinkOf(text)
	if type(text) ~= "string" then return nil end
	return text:match("|c.-|h|r") or text:match("|H.-|h.-|h") or text
end

local function Show(typeKey, values, icon)
	if ns.Router and ns.Router.Show then
		ns.Router.Show(typeKey, values, { icon = icon })
	end
end

-- Poor items are left out, unless they're quest items.
local function ShowItem(link, count, total)
	local _, _, quality, _, _, _, _, _, _, icon, _, classID = C_Item.GetItemInfo(link)
	if quality == nil then
		local _, _, _, _, instantIcon, instantClass = C_Item.GetItemInfoInstant(link)
		icon, classID = icon or instantIcon, classID or instantClass
	end
	if quality == POOR and classID ~= QUEST_ITEM then return end
	-- A total of 1 says nothing; without it the template drops "(%t)" with its brackets (Format).
	Show("LOOT", { e = link, a = count, t = total > 1 and total or nil }, icon)
end

local function Loot(args)
	local link = LinkOf(args.link)
	if type(link) ~= "string" then return end
	local count = tonumber(args.count) or 1
	-- Counted now: the bags may change again before an uncached item's data arrives.
	local total = (C_Item.GetItemCount(link) or 0) + count
	local quality = select(3, C_Item.GetItemInfo(link))
	if quality == nil and Item and Item.CreateFromItemLink then
		local item = Item:CreateFromItemLink(link)
		if not item:IsItemEmpty() then
			item:ContinueOnItemLoad(function()
				ns.SafeCall("CHAT_MSG_LOOT", ShowItem, link, count, total)
			end)
			return
		end
	end
	ShowItem(link, count, total)
end

local function Money(args)
	if type(args.money) ~= "string" then return end
	Show("MONEY", { e = args.money })
end

local function Currency(args)
	local link = LinkOf(args.link)
	if type(link) ~= "string" then return end
	local values = { e = link, a = tonumber(args.count) or 1 }
	local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfoFromLink and C_CurrencyInfo.GetCurrencyInfoFromLink(link)
	local icon
	if type(info) == "table" then
		values.t = ns.Readable(info.quantity)
		icon = ns.Readable(info.iconFileID)
	end
	Show("CURRENCY", values, icon)
end

local function Experience(args)
	local amount = tonumber(args.amount)
	if not amount then return end
	Show("EXPERIENCE", { a = amount, n = args.name })
end

local function Skill(args)
	if type(args.skill) ~= "string" then return end
	Show("SKILL", { s = args.skill, a = tonumber(args.rank) })
end

local HANDLERS = {
	CHAT_MSG_LOOT = Loot,
	CHAT_MSG_MONEY = Money,
	CHAT_MSG_CURRENCY = Currency,
	CHAT_MSG_COMBAT_XP_GAIN = Experience,
	CHAT_MSG_SKILL = Skill,
}

-- Skips the parsing when CTX is off or the type is (the router would drop the line anyway).
local function TypeOn(typeKey)
	local profile = ns.profile
	if not profile or profile.enabled == false then return false end
	local settings = ns.Router and ns.Router.TypeSettings and ns.Router.TypeSettings(typeKey)
		or profile.types and profile.types[typeKey]
	return not (settings and settings.enabled == false)
end

for event, handler in pairs(HANDLERS) do
	local typeKey = SOURCES[event].type
	ns.On(event, function(text)
		if ns.IsSecret(text) or type(text) ~= "string" then return end
		if not TypeOn(typeKey) then return end
		local args = Parse(event, text)
		if args then handler(args) end
	end)
end
