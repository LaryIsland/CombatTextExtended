local addonName, ns = ...

-- Templates (design document 4.6). A template is text with codes for an event's values (%a amount and the rest,
-- Notes/Architecture.md) and %% for a literal %. It's turned into pieces once, then each line joins the pieces with
-- `..`, which works on values the client hides (2.3): a hidden value is never looked at, tested or measured here, only
-- passed to BreakUpLargeNumbers or AbbreviateNumbers (both take hidden numbers) and joined.
--   ns.Format.Pieces(template)          cached list of literal strings and code tables ({ code = "a" })
--   ns.Format.Build(template, values)   the text, possibly hidden, or nil when there's nothing to show or joining failed
--   ns.Format.Amount(v)                 a number in the profile's number format

local Format = {}
ns.Format = Format

local CODES = { a = true, n = true, s = true, p = true, r = true, e = true, t = true }
-- Codes that are amounts, so they take the number format.
local AMOUNTS = { a = true, r = true, t = true }
-- One table per code, shared by every template, so pieces cost nothing per line.
local CODE = {}
for code in pairs(CODES) do
	CODE[code] = { code = code }
end

-- The joining text dropped with a code that has no value this time, as MSBT drops it: an empty pair of brackets
-- (with the space before it), or a " - " on either side.
local BRACKETS = { { "(", ")" }, { "[", "]" }, { "<", ">" } }
local DASH = " - "

local EMPTY = {}
local cache, cached = {}, 0
-- The Event Types popup builds a preview on every key press, so the cache is emptied now and then rather than kept.
local CACHE_LIMIT = 200

function Format.Pieces(template)
	if type(template) ~= "string" or ns.IsSecret(template) then return EMPTY end
	local pieces = cache[template]
	if pieces then return pieces end

	pieces = {}
	local literal = {}
	local function Flush()
		if #literal > 0 then
			local text = table.concat(literal)
			if text ~= "" then pieces[#pieces + 1] = text end
			for i = #literal, 1, -1 do literal[i] = nil end
		end
	end

	local i, length = 1, #template
	while i <= length do
		local percent = template:find("%", i, true)
		if not percent then
			literal[#literal + 1] = template:sub(i)
			break
		end
		literal[#literal + 1] = template:sub(i, percent - 1)
		local code = template:sub(percent + 1, percent + 1)
		if CODES[code] then
			Flush()
			pieces[#pieces + 1] = CODE[code]
			i = percent + 2
		elseif code == "%" then
			literal[#literal + 1] = "%"
			i = percent + 2
		else
			-- A % that isn't a code ("50%!") is kept as it is.
			literal[#literal + 1] = "%"
			i = percent + 1
		end
	end
	Flush()

	if cached >= CACHE_LIMIT then
		cache, cached = {}, 0
	end
	cache[template] = pieces
	cached = cached + 1
	return pieces
end

-- Numbers ------------------------------------------------------------------------------------------------------------

-- numbers: "full", "grouped" (BreakUpLargeNumbers, as Blizzard's own messages) or "short" (AbbreviateNumbers); nil for
-- the profile's. Anything that isn't a number (a name, a link) is returned as it is.
function Format.Amount(v, numbers)
	if type(v) ~= "number" then return v end
	numbers = numbers or (ns.profile and ns.profile.numbers) or "grouped"
	if numbers == "short" and AbbreviateNumbers then
		return AbbreviateNumbers(v)
	elseif numbers == "grouped" and BreakUpLargeNumbers then
		return BreakUpLargeNumbers(v)
	end
	return v
end

-- Building -----------------------------------------------------------------------------------------------------------
-- The parts of the line being built. Kept between calls, and emptied after each, so nothing hidden is held on to.

local parts, isLiteral = {}, {}
local count = 0
local stripNext = 0 -- characters to take off the front of the next literal piece
local trimNext = false -- the next literal piece loses its leading spaces
local droppedLast = false -- the last piece was a code with no value

local function EndsWith(text, ending)
	return #text >= #ending and text:sub(-#ending) == ending
end

local function StartsWith(text, start)
	return text:sub(1, #start) == start
end

-- Anything shown so far. Values aren't looked at (they may be hidden): only literal parts can be empty.
local function Visible()
	for i = 1, count do
		if not isLiteral[i] or parts[i] ~= "" then return true end
	end
	return false
end

-- Takes the joining text around a dropped code off the last literal part and the next literal piece, and never leaves
-- a space at the start of the line or two together.
local function Prune(nextPiece)
	local previous = count > 0 and isLiteral[count] and parts[count] or nil
	local following = type(nextPiece) == "string" and nextPiece or nil

	if previous and following then
		for _, pair in ipairs(BRACKETS) do
			local open, close = pair[1], pair[2]
			if EndsWith(previous, open) and StartsWith(following, close) then
				-- "+%a (%r)" with no %r: drop " (" and ")".
				local kept = previous:sub(1, #previous - #open):gsub("%s+$", "")
				parts[count] = kept
				stripNext = #close
				trimNext = not Visible()
				return
			end
		end
	end
	if previous and EndsWith(previous, DASH) then
		parts[count] = previous:sub(1, #previous - #DASH)
	elseif following and StartsWith(following, DASH) then
		stripNext = #DASH
		trimNext = not Visible()
	else
		trimNext = not Visible() or (previous ~= nil and previous:find("%s$") ~= nil)
	end
end

local function Add(value, literal)
	count = count + 1
	parts[count] = value
	isLiteral[count] = literal
end

-- A code's value is shown when there is one: a hidden value always counts (it can't be tested), a readable one when
-- it's a number or a non-empty string.
local function HasValue(v)
	if ns.IsSecret(v) then return true end
	local kind = type(v)
	return kind == "number" or (kind == "string" and v ~= "")
end

local function Collect(pieces, values, numbers)
	for index = 1, #pieces do
		local piece = pieces[index]
		if type(piece) == "string" then
			if stripNext > 0 then
				piece = piece:sub(stripNext + 1)
				stripNext = 0
			end
			if trimNext then
				piece = piece:gsub("^%s+", "")
				trimNext = false
			end
			if piece ~= "" then
				Add(piece, true)
				droppedLast = false
			end
		else
			local code = piece.code
			local v = values and values[code]
			if HasValue(v) then
				if AMOUNTS[code] then v = Format.Amount(v, numbers) end
				Add(v, false)
				trimNext, droppedLast = false, false
			else
				Prune(pieces[index + 1])
				droppedLast = true
			end
		end
	end
	-- "Hit %a %n" with no %n: no space left at the end.
	if droppedLast and count > 0 and isLiteral[count] then
		parts[count] = parts[count]:gsub("%s+$", "")
	end
	-- Pruning can leave empty literal parts behind.
	local text = ""
	for i = 1, count do
		local part = parts[i]
		if not (isLiteral[i] and part == "") then
			text = text .. part
		end
	end
	return text
end

local function Forget()
	for i = 1, count do
		parts[i] = nil
		isLiteral[i] = nil
	end
	count = 0
	stripNext = 0
	trimNext, droppedLast = false, false
end

-- values: { a = ..., n = ... }, any of them possibly hidden. numbers: as for Format.Amount (nil: the profile's).
-- Returns nil when the template has nothing to show this time, or when joining failed (design document 4.6: the caller
-- then falls back to Blizzard's message). Joining hidden values is beta check 4, so it's always done under pcall.
function Format.Build(template, values, numbers)
	local pieces = Format.Pieces(template)
	if #pieces == 0 then return nil end
	local ok, text = pcall(Collect, pieces, values, numbers)
	local joined = count
	Forget()
	if not ok then return nil end
	-- A readable empty result means every piece was dropped; a hidden one always has something in it.
	if joined == 0 or (not ns.IsSecret(text) and text == "") then return nil end
	return text
end
