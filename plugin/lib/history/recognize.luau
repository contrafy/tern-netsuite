--!strict
-- Which finished command lines were SuiteCloud deploys or uploads. The line
-- is what the shell reported (typed, not alias-expanded), so it may hold
-- several commands (`cd x && suitecloud project:deploy | tee log`): each
-- simple command is tried in turn, following `cd`/`pushd` so the deploy's directory
-- is known. Help and `--dryrun` change no account and are not deploys.

local Argv = require("../sdf/argv")
local Config = require("../config")

export type Match = {
	invocation: Argv.Invocation,
	command: string,
	-- Where the command ran; nil when a `cd` could not be followed.
	cwd: string?,
	segment: string,
	-- How far the line's exit status is the deploy's: "all" when the deploy
	-- is the last command, "success" when an earlier `&&` command may have
	-- failed instead, "none" when a pipe, `||`, `&` or later command decides.
	exit: Exit,
}

export type Exit = "all" | "success" | "none"

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
	-- Shell keywords that start a command inside a loop, conditional or group.
	["do"] = true,
	["then"] = true,
	["else"] = true,
	["elif"] = true,
	["!"] = true,
	["{"] = true,
}

-- `env` options whose value is the next word.
local ENV_ARG: { [string]: boolean } = { ["-u"] = true, ["-C"] = true, ["-P"] = true, ["-S"] = true }

local function trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$")) or s
end

type Piece = { text: string, sep: string }

-- Splits at unquoted `;`, `&&`, `||`, `|`, `&`, newlines and parentheses;
-- `&` next to a redirection (`2>&1`, `&>`) does not split. Each piece keeps
-- the separator that ended it ("" at the end); pieces may be empty.
local function split(line: string): { Piece }
	local out: { Piece } = {}
	local start = 1
	local quote: string? = nil
	local i = 1
	local n = #line
	local function cut(at: number, width: number)
		table.insert(out, { text = trim(string.sub(line, start, at - 1)), sep = string.sub(line, at, at + width - 1) })
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

-- The simple commands of a line, in order.
function M.segments(line: string): { string }
	local out: { string } = {}
	for _, p in split(line) do
		if p.text ~= "" then
			table.insert(out, p.text)
		end
	end
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
				-- `-u NAME`, `-C dir`, `-P path`, `-S string` take the next word.
				i += if ENV_ARG[words[i]] then 2 else 1
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

-- Separators that end a list: the status before them does not matter.
local LIST_END: { [string]: boolean } = { [";"] = true, ["\n"] = true, ["&"] = true }
-- Separators that leave the status of what precedes them as the line's.
local TRANSPARENT: { [string]: boolean } = { [";"] = true, ["\n"] = true, [")"] = true, [""] = true }

local function exitOf(pieces: { Piece }, at: number): Exit
	for j = at, #pieces do
		local p = pieces[j]
		if j > at and p.text ~= "" and p.text ~= "}" then
			return "none"
		end
		if not TRANSPARENT[p.sep] then
			return "none"
		end
	end
	local exit: Exit = "all"
	for j = at - 1, 1, -1 do
		local sep = pieces[j].sep
		if LIST_END[sep] then
			break
		elseif sep == "||" then
			return "none"
		elseif sep == "&&" then
			exit = "success"
		end
	end
	return exit
end

-- The exit status to record for a match: nil when it may not be the deploy's.
function M.status(m: Match, exit: number): number?
	if m.exit == "all" or (m.exit == "success" and exit == 0) then
		return exit
	end
	return nil
end

function M.line(line: string, opts: Options): Match?
	local cwd = opts.cwd
	local pieces = split(line)
	for at, piece in pieces do
		local seg = piece.text
		local words = simple(Argv.words(seg))
		local program = words[1]
		if program == nil then
			continue
		end
		if program == "cd" then
			cwd = cd(cwd, words, opts.home)
			continue
		end
		if program == "pushd" then
			-- Bare `pushd` and `pushd +N` swap with the stack, which is unknown.
			local arg = words[2]
			cwd = if arg == nil or string.match(arg, "^[+-]%d") then nil else cd(cwd, words, opts.home)
			continue
		end
		if program == "popd" then
			cwd = nil
			continue
		end
		local inv = Argv.parse({ program = program, args = table.move(words, 2, #words, 1, {}) }, opts.wrappers)
		if inv and M.COMMANDS[inv.command] and not inv.help and inv.flags.dryrun ~= true then
			return { invocation = inv, command = inv.command, cwd = cwd, segment = seg, exit = exitOf(pieces, at) }
		end
	end
	return nil
end

return M
