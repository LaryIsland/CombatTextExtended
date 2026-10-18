local addonName, ns = ...
local L = ns.L

-- /ctx (design document 4.2). On its own it opens the options page; the rest open CTX's other places.
-- Nothing here opens in combat: each place it opens refuses then itself.

local HELP = { L.HELP_OPTIONS, L.HELP_TYPES, L.HELP_TEST, L.HELP_HELP }

local function Args(text)
	local args = {}
	for word in tostring(text or ""):gmatch("%S+") do
		args[#args + 1] = word
	end
	return args
end

local commands = {}

function commands.help()
	for _, line in ipairs(HELP) do ns.Print(line) end
	-- The probe is a development tool and isn't packaged, so it's only listed when it's there (and in English).
	if ns.Probe and ns.Probe.Run then
		ns.Print("/ctx probe start | stop | show - record and show what the client exposes for the beta checks")
	end
end

function commands.types()
	if ns.EventTypes and ns.EventTypes.Open then ns.EventTypes.Open() end
end

function commands.test()
	if ns.TestMode and ns.TestMode.Toggle then ns.TestMode.Toggle() end
end

function commands.probe(args)
	if not (ns.Probe and ns.Probe.Run) then return commands.help() end
	ns.Probe.Run(args)
end

local function OpenOptions()
	if ns.Options and ns.Options.Open then ns.Options.Open() end
end

SLASH_COMBATTEXTEXTENDED1 = "/ctx"
SLASH_COMBATTEXTEXTENDED2 = "/combattextextended"
SlashCmdList.COMBATTEXTEXTENDED = function(text)
	local args = Args(text)
	local name = args[1] and args[1]:lower()
	local command = name and commands[name]
	if command then
		command(args)
	elseif name then
		commands.help()
	else
		OpenOptions()
	end
end
