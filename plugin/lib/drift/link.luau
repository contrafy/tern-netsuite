--!strict
-- Links of the `drift` area. Any program can print a link, so a link never
-- runs the CLI: `tern-netsuite://drift[?cwd=<dir>]` opens the block held
-- (it reads the project and shows a cached result, and imports nothing
-- before Enter). The palette command opens the block directly.

export type Parsed = { cwd: string? }

local M = {}

M.BLOCK = "tern-netsuite.drift"
M.BASE = "tern-netsuite://drift"
-- Block argument: wait for Enter before running the CLI.
M.HOLD_FLAG = "--hold"

local function encode(s: string): string
	return (
		string.gsub(s, "[^%w%-%._~/]", function(c: string): string
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

local function decode(s: string): string
	return (
		string.gsub(s, "%%(%x%x)", function(h: string): string
			return string.char(tonumber(h, 16) :: number)
		end)
	)
end

function M.url(cwd: string?): string
	return if cwd then M.BASE .. "?cwd=" .. encode(cwd) else M.BASE
end

-- nil for anything but a bare link or one naming an absolute directory.
function M.parse(url: string): Parsed?
	if url == M.BASE or url == M.BASE .. "/" then
		return { cwd = nil }
	end
	local raw = string.match(url, "^tern%-netsuite://drift/?%?cwd=([^&#]*)$")
	if raw == nil then
		return nil
	end
	local cwd = decode(raw)
	if string.sub(cwd, 1, 1) ~= "/" or string.find(cwd, "%c") then
		return nil
	end
	return { cwd = cwd }
end

function M.blockArgs(cwd: string?, held: boolean): { string }
	local args: { string } = {}
	if held then
		table.insert(args, M.HOLD_FLAG)
	end
	if cwd then
		table.insert(args, cwd)
	end
	return args
end

function M.fromArgs(args: { string }): (string?, boolean)
	local cwd: string? = nil
	local held = false
	for _, a in args do
		if a == M.HOLD_FLAG then
			held = true
		elseif cwd == nil and string.sub(a, 1, 1) == "/" then
			cwd = a
		end
	end
	return cwd, held
end

return table.freeze(M)
