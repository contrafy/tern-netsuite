--!strict
-- Prints what plugin/lib/sdf/cli_slot.luau generates, for
-- tests/shell/cli-slot/run.sh. Run from this directory:
--
--   luau slot.luau -a script                                  the slot script
--   luau slot.luau -a acquire                                 its acquire part (the guard's copy)
--   luau slot.luau -a lock DATA [AUTHID]                      an auth ID's lock directory
--   luau slot.luau -a pane CWD LOCK TITLE INTRO ARGV...       a pane's command line (LOCK - : none)

local CliSlot = require("../../../plugin/lib/sdf/cli_slot")

local args = { ... }
local cmd = args[1]

if cmd == "script" then
	print(CliSlot.SCRIPT)
elseif cmd == "acquire" then
	print(CliSlot.ACQUIRE)
elseif cmd == "lock" then
	print(CliSlot.lockPath(args[2], args[3]))
elseif cmd == "pane" then
	local argv = table.move(args, 6, #args, 1, {})
	local script, err = CliSlot.paneScript({
		cwd = args[2],
		lock = if args[3] == "-" then nil else args[3],
		title = args[4],
		intro = args[5],
		argv = argv,
	})
	if script == nil then
		error(tostring(err), 0)
	end
	print(CliSlot.paneLine(script))
else
	error("usage: slot.luau -a script | acquire | lock DATA [AUTHID] | pane CWD LOCK TITLE INTRO ARGV...")
end
