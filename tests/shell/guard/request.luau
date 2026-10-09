--!strict
-- Inspects a guard request for tests/shell/guard/run.sh with the plugin's
-- own parser, so the shell guard and the approve block are checked against
-- each other. Run from this directory:
--
--   luau request.luau -a strict JSON          parses like the block (exit 1 if refused)
--   luau request.luau -a canon JSON           the fingerprint canonical string
--   luau request.luau -a field JSON KEY       a top-level value ("null" when absent)
--   luau request.luau -a argv JSON ARG...     exit 1 unless argv equals ARG...
--   luau request.luau -a files JSON           the listed file paths, one per line
--   luau request.luau -a notes JSON           the notes, one per line

local Protocol = require("../../../plugin/lib/guard/protocol")
local json = require("../../lib/json")

local args = { ... }
local cmd, text = args[1], args[2]
assert(type(cmd) == "string" and type(text) == "string", "usage: request.luau -a CMD JSON [ARGS...]")

local doc = json.decode(text)
local nonce = if type(doc) == "table" and type(doc.nonce) == "string" then doc.nonce else "x"
local r, err = Protocol.parse("/spool/tern-netsuite/spool/req-" .. nonce .. ".json", text, json.decode)

local function out(s: string)
	-- print adds the final newline back.
	print((string.gsub(s, "\n$", "")))
end

if cmd == "strict" then
	if r == nil then
		error("the block refuses the request: " .. tostring(err), 0)
	end
	print("ok")
elseif cmd == "field" then
	local v = doc[args[3]]
	print(if v == nil or v == json.null then "null" else tostring(v))
else
	if r == nil then
		error("the block refuses the request: " .. tostring(err), 0)
	end
	local req = r :: Protocol.Request
	if cmd == "canon" then
		out((assert(Protocol.canonical(Protocol.fingerprintInput(req)), "canonical")))
	elseif cmd == "argv" then
		local want = table.move(args, 3, #args, 1, {})
		if #want ~= #req.argv then
			error(string.format("argv has %d items, want %d", #req.argv, #want), 0)
		end
		for i, a in want do
			if req.argv[i] ~= a then
				error(string.format("argv[%d] = %q, want %q", i, req.argv[i], a), 0)
			end
		end
		print("ok")
	elseif cmd == "files" then
		for _, f in req.files do
			print(f.path)
		end
	elseif cmd == "notes" then
		for _, n in req.notes do
			print(n)
		end
	else
		error("unknown command " .. cmd, 0)
	end
end

return nil
