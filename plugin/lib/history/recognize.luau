--!strict
-- Which finished command lines were SuiteCloud deploys or uploads. The line
-- is what the shell reported (typed, not alias-expanded), so it may hold
-- several commands (`cd x && suitecloud project:deploy | tee log`): each
-- simple command is tried in turn, following `cd` so the deploy's directory
-- is known. Help and `--dryrun` change no account and are not deploys.

local Argv = require("../sdf/argv")
local Config = require("../config")

export type Match = {
	invocation: Argv.Invocation,
	command: string,
	-- Where the command ran; nil when a `cd` could not be followed.
	cwd: string?,
	segment: string,
}

export type Options = {
	-- The pane's directory when the line started.
	cwd: string?,
	home: string?,
	wrappers: { Config.Wrapper }?,
}

local M = {}

M.COMMANDS = table.freeze({ ["project:deploy"] = true, ["file:upload"] = true })

-- Words that run the rest of the line as the command.
local PREFIXES: { [string]: boolean } = {
	command = true,
	exec = true,
	time = true,
	noglob = true,
	nocorrect = true,
	builtin = true,
}

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) or s
end

-- Splits at unquoted `;`, `&&`, `||`, `|`, `&`, newlines and parentheses;
-- `&` next to a redirection (`2>&1`, `&>`) does not split.
function M.segments(line: string): { string }
	local out: { string } = {}
	local start = 1
	local quote: string? = nil
	local i = 1
	local n = #line
	local function cut(at: number, width: number)
		local seg = trim(string.sub(line, start, at - 1))
		if seg ~= "" then
			table.insert(out, seg)
		end
		start = at + width
	end
	while i <= n do
		local c = string.sub(line, i, i)
		if quote then
			if c == quote then
				quote = nil
			elseif c == "\\" and quote == '"' then
				i += 1
			end
		elseif c == "'" or c == '"' then
			quote = c
		elseif c == "\\" then
			i += 1
		elseif c == ";" or c == "\n" or c == "(" or c == ")" then
			cut(i, 1)
		elseif c == "|" then
			local width = if string.sub(line, i + 1, i + 1) == "|" then 2 else 1
			cut(i, width)
			i += width - 1
		elseif c == "&" then
			local prev = string.sub(line, i - 1, i - 1)
			local nextc = string.sub(line, i + 1, i + 1)
			if nextc == "&" then
				cut(i, 2)
				i += 1
			elseif prev ~= ">" and prev ~= "<" and nextc ~= ">" then
				cut(i, 1)
			end
		end
		i += 1
	end
	cut(n + 1, 0)
	return out
end

local function isAssignment(w: string): boolean
	return string.match(w, "^[%a_][%w_]*=") ~= nil
end

-- Drops `VAR=x` prefixes and words like `command`/`env` that run the rest.
local function simple(words: { string }): { string }
	local i = 1
	while i <= #words do
		local w = words[i]
		if isAssignment(w) or PREFIXES[w] then
			i += 1
		elseif w == "env" then
			i += 1
			while i <= #words and (isAssignment(words[i]) or string.sub(words[i], 1, 1) == "-") do
				i += 1
			end
		else
			break
		end
	end
	return table.move(words, i, #words, 1, {})
end

local function normalize(path: string): string
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

local function cd(cwd: string?, words: { string }, home: string?): string?
	local i = 2
	while words[i] == "-P" or words[i] == "-L" or words[i] == "--" do
		i += 1
	end
	local arg = words[i]
	if arg == nil or arg == "~" then
		return home
	end
	if arg == "-" or string.find(arg, "[%$`*?]") then
		return nil
	end
	if string.sub(arg, 1, 2) == "~/" then
		return if home then normalize(home .. string.sub(arg, 2)) else nil
	end
	if string.sub(arg, 1, 1) == "/" then
		return normalize(arg)
	end
	if string.sub(arg, 1, 1) == "~" then
		return nil
	end
	return if cwd then normalize(cwd .. "/" .. arg) else nil
end

function M.line(line: string, opts: Options): Match?
	local cwd = opts.cwd
	for _, seg in M.segments(line) do
		local words = simple(Argv.words(seg))
		local program = words[1]
		if program == nil then
			continue
		end
		if program == "cd" then
			cwd = cd(cwd, words, opts.home)
			continue
		end
		local inv = Argv.parse({ program = program, args = table.move(words, 2, #words, 1, {}) }, opts.wrappers)
		if inv and M.COMMANDS[inv.command] and not inv.help and inv.flags.dryrun ~= true then
			return { invocation = inv, command = inv.command, cwd = cwd, segment = seg }
		end
	end
	return nil
end

return M
