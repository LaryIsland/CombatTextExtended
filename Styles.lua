local addonName, ns = ...
local L = ns.L

-- Animation styles (design document 4.1): each is a scroll function for Blizzard's CombatTextMixin:AddMessage, called
-- by Blizzard's OnUpdate every frame with the engine (an area's frame, Areas.lua) and the line (a font string with
-- Blizzard's fields startX, startY, endY, xDir, scrollTime, yPos, isCrit, and CTX's `ctx` table). It returns where the
-- line's TOP goes, for SetPoint("TOP", WorldFrame, "BOTTOM", x, y), in the line's own scale. engine.ctxGeom is the
-- area in the same units: { left, right, bottom, top, centerX, width, height }.
--
-- Blizzard's own styles (Blizzard, up or down, and Arc) are Blizzard's CombatTextUtil.StandardScroll and
-- FountainScroll. MSBT's (Parabola, Angled, Static; sticky Pow and Static) are written here from how MSBT moves its
-- text; none of MSBT's code is used. Nothing here reads or touches the text itself, which may be hidden (2.3): only positions,
-- heights and times, all readable.
--
-- The line clock: Blizzard's OnUpdate adds the frame's time to line.scrollTime, releases the line at 1.9 s and fades
-- it from 1.3 s. Each style first calls Styles.Advance, which keeps the line's own time (ctx.t) and puts scrollTime at
-- the same point of Blizzard's 1.9 s, so a line lasts its area's duration and Blizzard's fade, release and crit grow
-- and shrink follow at that pace.

local Styles = { normal = {}, sticky = {}, normalOrder = {}, stickyOrder = {} }
ns.Styles = Styles

-- Blizzard's numbers (CombatTextConstants), for when Blizzard_CombatText hasn't loaded yet.
local SCROLL_TIME, FADE_TIME, MESSAGE_HEIGHT = 1.9, 1.3, 25
-- MSBT's space between lines, in text units.
local GAP = 8
-- Every line is this wide, so justifying it left, centre or right lines its text up with the area's edge without
-- measuring it (text width may be hidden). Wide enough that no line is cut short.
local LINE_WIDTH = 2000
Styles.LINE_WIDTH = LINE_WIDTH
Styles.MESSAGE_HEIGHT = MESSAGE_HEIGHT
Styles.GAP = GAP

-- Angled: the part of a line's time spent moving out, and when the slide that ends it starts (Blizzard's fade).
local ANGLED_MOVE = 0.45
local ANGLED_FINISH = 0.85 -- how far across the area the line moves before holding
-- Pow: the shrink after a line appears (s), how much bigger it starts, and how often Jiggle moves it (s).
local POW_GROW, POW_SIZE, JIGGLE_EVERY = 0.17, 0.7, 0.05
-- Blizzard's Arc rises this far (FountainScroll's radius, which it doesn't scale).
local ARC_RADIUS = 150

local ALIGN_FRACTION = { left = 0, center = 0.5, right = 1 }

local function ScrollTime()
	local constants = CombatTextConstants
	return constants and constants.MessageScrollSpeed or SCROLL_TIME
end

local function FadeTime()
	local constants = CombatTextConstants
	return constants and constants.MessageFadeOutTime or FADE_TIME
end

local function Random(low, high)
	if fastrandom then return fastrandom(low, high) end
	return math.random(low, high)
end

-- The clock ------------------------------------------------------------------------------------------------------------

-- Returns the line's progress, 0 to 1. ctx.t can also be moved on by a style's place function (MSBT's way of keeping
-- lines apart); the next call carries on from there.
function Styles.Advance(line, duration)
	local total = ScrollTime()
	local ctx = line.ctx
	if not ctx then return math.min(line.scrollTime / total, 1) end
	local elapsed = line.scrollTime - (ctx.warped or 0)
	local t = (ctx.t or 0) + (elapsed > 0 and elapsed or 0)
	ctx.t = t
	if not duration or duration <= 0 then duration = total end
	local progress = t / duration
	if progress > 1 then progress = 1 end
	line.scrollTime = total * progress
	ctx.warped = line.scrollTime
	return progress
end
local Advance = Styles.Advance

-- The alpha Blizzard's OnUpdate gives a line at this scrollTime (for the icon beside it, which Blizzard doesn't know).
function Styles.FadeAlpha(scrollTime)
	local fade, total = FadeTime(), ScrollTime()
	if scrollTime < fade then return 1 end
	local alpha = 1 - (scrollTime - fade) / (total - fade)
	return alpha > 0 and alpha or 0
end

-- Positions ------------------------------------------------------------------------------------------------------------

-- Where a line's TOP goes so that its aligned edge (left edge, centre or right edge) is at x.
local function Anchor(x, align)
	if align == "left" then
		return x + LINE_WIDTH / 2
	elseif align == "right" then
		return x - LINE_WIDTH / 2
	end
	return x
end
Styles.Anchor = Anchor

-- The aligned edge's own place in the area: the left edge, the middle or the right edge.
local function AlignedX(geom, align)
	return geom.left + geom.width * (ALIGN_FRACTION[align] or 0.5)
end

-- The height a line settles at: the crit size for crits, the text size otherwise.
local function Height(line)
	local ctx = line.ctx
	return ctx and ctx.h or MESSAGE_HEIGHT
end

-- The range a line's TOP moves in: from one line above the bottom (so the text is inside the area) to the top.
local function Track(geom, height)
	local low, high = geom.bottom + height, geom.top
	if high < low then high = low end
	return low, high
end

-- Picks a choice the style offers: the stored one, or the style's first when it offers no such thing (false, or a
-- value from another style).
function Styles.Choice(list, value)
	if not list or list[1] == nil then return false end
	for _, entry in ipairs(list) do
		if entry == value then return value end
	end
	return list[1]
end
local Choice = Styles.Choice

-- Lines that move in time with each other: the engine's other active lines of the same style, normal or sticky.
local function SameStyle(other, line)
	local a, b = other.ctx, line.ctx
	return a and b and a.style == b.style and a.sticky == b.sticky
end

-- MSBT keeps scrolling lines apart by moving older lines on in time, never by moving the new one: walking back from
-- the newest, each older line must be at least a line's height (plus the gap) ahead of the one after it.
local function KeepApart(engine, line)
	local ctx = line.ctx
	local low, high = Track(engine.ctxGeom, ctx.h)
	local travel = high - low
	if travel <= 0 or not ctx.duration or ctx.duration <= 0 then return end
	local perUnit = ctx.duration / travel
	local up = engine.ctxDirection ~= "down"
	local newer = line
	local active = engine.activeFontStrings
	for i = #active, 1, -1 do
		local older = active[i]
		if older ~= line and SameStyle(older, line) then
			-- Scrolling up the older line is above, so its own height matters; scrolling down, the newer one's.
			local gap = ((up and Height(older) or Height(newer)) + GAP) * perUnit
			local needed = (newer.ctx.t or 0) + gap
			if (older.ctx.t or 0) >= needed then break end
			older.ctx.t = needed
			newer = older
		end
	end
end

-- Slots: Angled and Static put each line in the first free one, counting from where the style starts (the highest
-- angle, or the first row). first: the first slot's position; step: the distance to the next (negative going down);
-- last: as far as they go. taken(position) says whether a showing line is there. When every slot is taken, nil.
local function FreeSlot(first, step, last, taken)
	local position = first
	while (step > 0 and position <= last) or (step < 0 and position >= last) do
		if not taken(position) then return position end
		position = position + step
	end
	return nil
end

-- Whether another showing line of the style is within a line (plus the gap) of position. field: where ctx keeps a
-- line's position.
local function Occupied(engine, line, field, position)
	local h = line.ctx.h
	for _, other in ipairs(engine.activeFontStrings) do
		local o = other.ctx
		if other ~= line and o and o[field] and SameStyle(other, line) then
			if math.abs(o[field] - position) < math.max(h, Height(other)) + GAP - 0.01 then return true end
		end
	end
	return false
end

Styles.KeepApart = KeepApart

-- Normal styles ----------------------------------------------------------------------------------------------------

local function AddNormal(style)
	Styles.normal[style.key] = style
	table.insert(Styles.normalOrder, style.key)
end

local function AddSticky(style)
	Styles.sticky[style.key] = style
	table.insert(Styles.stickyOrder, style.key)
end

-- Blizzard's own Up and Down (StandardScroll): straight from one end of the area to the other, with the start and end
-- points from the area (Styles.Layout) and Blizzard's stacking, stagger and sideways shift from AddMessage.
AddNormal({
	key = "blizzard",
	label = L.STYLE_BLIZZARD,
	directions = { "up", "down" },
	stacks = true, -- lines start where Blizzard's stacking puts them (the area's When Busy setting)
	scroll = function(engine, line)
		Advance(line, line.ctx and line.ctx.duration)
		return CombatTextUtil.StandardScroll(engine, line)
	end,
})

-- Blizzard's Arc (FountainScroll): up and out to the side, alternating sides. Blizzard's rises a fixed 150, so it's
-- scaled to the area's height, keeping its shape; Down is the same arc upside down.
AddNormal({
	key = "arc",
	label = L.STYLE_ARC,
	directions = { "up", "down" },
	stacks = true,
	scroll = function(engine, line)
		Advance(line, line.ctx and line.ctx.duration)
		local x, y = CombatTextUtil.FountainScroll(engine, line)
		local scale = engine.ctxArcScale or 1
		local rise = (y - line.startY) * scale
		if engine.ctxDirection == "down" then rise = -rise end
		return line.startX + (x - line.startX) * scale, line.startY + rise
	end,
})

-- Straight up or down through the area (Parabola's path).
local function StraightY(engine, line, progress)
	local low, high = Track(engine.ctxGeom, line.ctx.h)
	if engine.ctxDirection == "down" then
		return high - (high - low) * progress
	end
	return low + (high - low) * progress
end

-- As Straight, curving: the aligned edge is at one side of the area halfway up, and at the other at the top and
-- bottom (Left bulges towards the left).
AddNormal({
	key = "parabola",
	label = L.STYLE_PARABOLA,
	directions = { "up", "down" },
	behaviors = { "left", "right" },
	scroll = function(engine, line)
		local ctx = line.ctx
		local geom = engine.ctxGeom
		local progress = Advance(line, ctx.duration)
		local fromMiddle = progress * 2 - 1
		local across = geom.width * fromMiddle * fromMiddle
		local x
		if engine.ctxBehavior == "right" then
			x = geom.left + geom.width - across
		else
			x = geom.left + across
		end
		return Anchor(x, ctx.align), StraightY(engine, line, progress)
	end,
	place = KeepApart,
})

-- Out at an angle to a point most of the way across the area, a hold, then a slide to the side while fading. Each
-- line takes the highest angle no showing line has (the lowest, for Down), a line lower each time while the area is
-- busy; when every one is taken it takes the highest. Alternate sends lines left and right in turn from the middle,
-- aligned to the side they move away from.
AddNormal({
	key = "angled",
	label = L.STYLE_ANGLED,
	directions = { "left", "right", "alternate" },
	behaviors = { "up", "down" },
	place = function(engine, line)
		local ctx = line.ctx
		local state = engine.ctxState
		local low, high = Track(engine.ctxGeom, ctx.h)
		local travel = high - low
		local top = travel - (ctx.h + GAP)
		if top < 0 then top = travel end
		ctx.finish = FreeSlot(top, -(ctx.h + GAP), 0, function(finish)
			return Occupied(engine, line, "finish", finish)
		end) or top

		local direction = engine.ctxDirection
		if direction == "alternate" then
			state.angledSide = -(state.angledSide or -1)
			ctx.side = state.angledSide
			ctx.start = 0.5
			ctx.align = ctx.side > 0 and "left" or "right"
			line:SetJustifyH(ctx.side > 0 and "LEFT" or "RIGHT")
		else
			ctx.side = direction == "left" and -1 or 1
			ctx.start = 0
		end
	end,
	scroll = function(engine, line)
		local ctx = line.ctx
		local geom = engine.ctxGeom
		local progress = Advance(line, ctx.duration)
		local slide = FadeTime() / ScrollTime()
		local width = geom.width
		local start, finish = width * (ctx.start or 0), width * ANGLED_FINISH
		local across, rise
		if progress < ANGLED_MOVE then
			local part = progress / ANGLED_MOVE
			across = start + (finish - start) * part
			rise = (ctx.finish or 0) * part
		elseif progress < slide then
			across, rise = finish, ctx.finish or 0
		else
			local part = (progress - slide) / (1 - slide)
			across = finish + (width - finish) * part
			rise = ctx.finish or 0
		end
		if ctx.side and ctx.side < 0 then across = width - across end
		local low, high = Track(geom, ctx.h)
		local y = engine.ctxBehavior == "down" and (high - rise) or (low + rise)
		return Anchor(geom.left + across, ctx.align), y
	end,
})

-- Static: no movement. Each line takes the first free row from the top (from the bottom, going up). When every row
-- is taken it goes a line below (or above) the last, starting again at the far end when it runs out of room, and
-- older lines it lands on end at once. Shared with the sticky Static style, so the two never overlap.
local function PlaceStatic(engine, line, down)
	local ctx = line.ctx
	local state = engine.ctxState
	local low, high = Track(engine.ctxGeom, ctx.h)
	local function Taken(y)
		for _, other in ipairs(engine.activeFontStrings) do
			local o = other.ctx
			if other ~= line and o and o.static and o.y and o.y - Height(other) - GAP < y and y - ctx.h - GAP < o.y then
				return true
			end
		end
		return false
	end
	local y
	if down then
		y = FreeSlot(high, -(ctx.h + GAP), low, Taken)
	else
		y = FreeSlot(low, ctx.h + GAP, high, Taken)
	end
	if y == nil then
		if state.staticY == nil then
			y = down and high or low
		elseif down then
			y = state.staticY - ((state.staticH or ctx.h) + GAP)
			if y < low then y = high end
		else
			y = state.staticY + ctx.h + GAP
			if y > high then y = low end
		end
	end
	ctx.y = y
	ctx.static = true

	-- A line occupies [y - height, y].
	local newest = state.staticLine
	for _, other in ipairs(engine.activeFontStrings) do
		local o = other.ctx
		if other ~= line and other ~= newest and o and o.static and o.y then
			if o.y - Height(other) < y and y - ctx.h < o.y then
				o.t = math.max(o.t or 0, o.duration or 0)
			end
		end
	end
	state.staticY, state.staticH, state.staticLine = y, ctx.h, line
end

local function StaticScroll(engine, line)
	local ctx = line.ctx
	Advance(line, ctx.duration)
	return Anchor(AlignedX(engine.ctxGeom, ctx.align), ctx.align), ctx.y or engine.ctxGeom.top
end

AddNormal({
	key = "static",
	label = L.STYLE_STATIC,
	directions = { "up", "down" },
	place = function(engine, line)
		PlaceStatic(engine, line, engine.ctxDirection == "down")
	end,
	scroll = StaticScroll,
})

-- Sticky styles ----------------------------------------------------------------------------------------------------
-- For crits and other text that stays in place (Blizzard's "crit" and "sticky", or a type set to always sticky).

-- Blizzard's crit: StandardScroll with endY at the start (AddMessage sets that for crits and sticky lines), so it
-- grows, shrinks and stays where Blizzard's stacking put it.
AddSticky({
	key = "blizzard",
	label = L.STYLE_BLIZZARD,
	scroll = function(engine, line)
		Advance(line, line.ctx and line.ctx.duration)
		return CombatTextUtil.StandardScroll(engine, line)
	end,
})

-- Pow: appears larger and shrinks to size, then holds in the middle of the area; Jiggle shakes it a little until it
-- starts to fade. Showing lines are stacked around the middle, newest at the bottom, each time one arrives.
AddSticky({
	key = "pow",
	label = L.STYLE_POW,
	behaviors = { "normal", "jiggle" },
	place = function(engine, line)
		local geom = engine.ctxGeom
		local ctx = line.ctx
		ctx.pow = true
		ctx.jiggle = engine.ctxStickyBehavior == "jiggle"
		-- Pow has its own grow; Blizzard's would fight it.
		line.isCrit = nil

		local active = engine.activeFontStrings
		local total = 0
		for _, other in ipairs(active) do
			if other.ctx and other.ctx.pow then total = total + Height(other) + GAP end
		end
		total = total - GAP
		local y = (geom.bottom + geom.top) / 2 + total / 2
		for _, other in ipairs(active) do
			local o = other.ctx
			if o and o.pow then
				o.restY = y
				y = y - (Height(other) + GAP)
			end
		end
		ctx.restX = Anchor(AlignedX(geom, ctx.align), ctx.align)
	end,
	scroll = function(engine, line)
		local ctx = line.ctx
		Advance(line, ctx.duration)
		local t, height = ctx.t or 0, ctx.h or MESSAGE_HEIGHT
		if t < POW_GROW then
			ns.Areas.SetHeight(line, height * (1 + (1 - t / POW_GROW) * POW_SIZE))
		elseif not ctx.sized then
			ns.Areas.SetHeight(line, height)
			ctx.sized = true
		end
		-- After the shrink and before the fade, a step of -1, 0 or 1 each way now and then; it stays put while fading.
		if ctx.jiggle and t >= POW_GROW and line.scrollTime < FadeTime() and t - (ctx.jiggleAt or 0) >= JIGGLE_EVERY then
			ctx.jiggleAt = t
			ctx.jiggleX, ctx.jiggleY = Random(-1, 1), Random(-1, 1)
		end
		local geom = engine.ctxGeom
		local x = ctx.restX or Anchor(AlignedX(geom, ctx.align), ctx.align)
		local y = ctx.restY or (geom.bottom + geom.top) / 2
		return x + (ctx.jiggleX or 0), y + (ctx.jiggleY or 0)
	end,
})

-- Static, as the normal style, from the top down.
AddSticky({
	key = "static",
	label = L.STYLE_STATIC,
	place = function(engine, line)
		line.isCrit = nil
		PlaceStatic(engine, line, true)
	end,
	scroll = StaticScroll,
})

-- An area's layout ------------------------------------------------------------------------------------------------------

-- Called from the engine's UpdateDisplayedMessages once engine.ctxGeom is current: picks the area's styles and
-- choices and sets Blizzard's textLocations, which AddMessage uses for where new lines start and how they stack.
-- Starting again clears what the styles remember about earlier lines.
function Styles.Layout(engine)
	local settings = engine.ctxSettings or {}
	local geom = engine.ctxGeom
	local normal = Styles.normal[settings.style] or Styles.normal.blizzard
	local sticky = Styles.sticky[settings.stickyStyle] or Styles.sticky.blizzard
	local direction = Choice(normal.directions, settings.direction)

	engine.ctxStyle = normal
	engine.ctxStickyStyle = sticky
	engine.ctxDirection = direction
	engine.ctxBehavior = Choice(normal.behaviors, settings.behavior)
	engine.ctxStickyBehavior = Choice(sticky.behaviors, settings.stickyBehavior)

	local align = ALIGN_FRACTION[settings.align] and settings.align or "center"
	engine.ctxAlign = align
	local locations = engine.textLocations
	local x = Anchor(AlignedX(geom, align), align)
	locations.startX, locations.endX = x, x
	-- Lines run the area's height: up from its bottom to its top, or down from its top to its bottom (the text inside
	-- the box at both ends). Going up, Blizzard's AddMessage starts a line a line lower than its start point (it stacks
	-- from the new line's bottom, Areas.lua's MeasureDrop), so both points go up by that much. The default box
	-- (Presets.lua) is where Blizzard's own text goes. Blizzard's stacking puts lines that arrive together below the
	-- start (above it, going down), and once they reach 130 below it shifts the next one sideways by 80, as the
	-- game's own text does. The arc is scaled so it rises the area's height.
	local low, high = Track(geom, MESSAGE_HEIGHT)
	engine.ctxArcScale = (high - low) / ARC_RADIUS
	if direction == "down" then
		locations.startY, locations.endY = high, low
	else
		local drop = engine.ctxDrop or 0
		locations.startY, locations.endY = low + drop, high + drop
	end

	local state = engine.ctxState
	for key in pairs(state) do state[key] = nil end
end
