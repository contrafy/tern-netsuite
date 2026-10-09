--!strict
-- Re-derives the SuiteCloud command a lens claimed from its argv. Claim globs
-- over-claim, so anything this cannot place returns nil and the lens stays
-- raw. Recognized launchers: `suitecloud <cmd>`, `npx [opts] suitecloud
-- <cmd>`, `npx [opts] @oracle/suitecloud-cli[@ver] <cmd>`, and the config's
-- `lens.wrappers` prefixes (whole words, longest prefix wins).

local Commands = require("./commands")
local Config = require("../config")

type Wrapper = Config.Wrapper

export type Run = { program: string, args: { string }, line: string?, typed: string? }

export type Invocation = {
	command: string,
	flags: { [string]: string | true },
	positional: { string },
	authId: string?,
	project: string?,
	interactive: boolean,
	help: boolean,
	-- What ran the command: "suitecloud", "npx suitecloud",
	-- "npx @oracle/suitecloud-cli" or the matching wrapper prefix.
	launcher: string,
	viaWrapper: string?,
}

local M = {}

-- Options that take no value; any other `--name` followed by a word takes it.
local BOOLEAN: { [string]: boolean } = {
	server = true,
	applyinstallprefs = true,
	interactive = true,
	help = true,
	dryrun = true,
	validate = true,
	overwrite = true,
	list = true,
	version = true,
}

local SHORT: { [string]: string } = { i = "interactive", h = "help", a = "applyinstallprefs" }

-- Options whose value is a space-separated list (`--paths a b`).
local VARIADIC: { [string]: boolean } = { paths = true, type = true }

-- npx options that take a value; the package to run follows the options.
local NPX_VALUE: { [string]: boolean } = { ["-p"] = true, ["--package"] = true, ["--cache"] = true }

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

-- Splits a typed command line into words (single/double quotes, backslash).
function M.words(line: string): { string }
	local out: { string } = {}
	local cur: { string } = {}
	local quote: string? = nil
	local started = false
	local i = 1
	local n = #line
	while i <= n do
		local c = string.sub(line, i, i)
		if quote then
			if c == quote then
				quote = nil
			elseif c == "\\" and quote == '"' and i < n then
				i += 1
				table.insert(cur, string.sub(line, i, i))
			else
				table.insert(cur, c)
			end
		elseif c == "'" or c == '"' then
			quote = c
			started = true
		elseif c == "\\" and i < n then
			i += 1
			table.insert(cur, string.sub(line, i, i))
			started = true
		elseif string.find(c, "%s") then
			if started then
				table.insert(out, table.concat(cur))
				table.clear(cur)
				started = false
			end
		else
			table.insert(cur, c)
			started = true
		end
		i += 1
	end
	if started then
		table.insert(out, table.concat(cur))
	end
	return out
end

type Parsed = {
	flags: { [string]: string | true },
	positional: { string },
}

local function parseOptions(words: { string }, from: number): Parsed
	local flags: { [string]: string | true } = {}
	local positional: { string } = {}
	local i = from
	while i <= #words do
		local w = words[i]
		local long, value = string.match(w, "^%-%-([^=]+)=(.*)$")
		if long and value then
			flags[long] = value
		elseif w == "--" then
			table.move(words, i + 1, #words, #positional + 1, positional)
			break
		elseif string.sub(w, 1, 2) == "--" then
			local name = string.sub(w, 3)
			if VARIADIC[name] then
				local parts: { string } = {}
				while i + 1 <= #words and string.sub(words[i + 1], 1, 1) ~= "-" do
					i += 1
					table.insert(parts, words[i])
				end
				flags[name] = if #parts > 0 then table.concat(parts, " ") else true
			elseif not BOOLEAN[name] and i + 1 <= #words and string.sub(words[i + 1], 1, 1) ~= "-" then
				i += 1
				flags[name] = words[i]
			else
				flags[name] = true
			end
		elseif string.match(w, "^%-%a+$") then
			for j = 2, #w do
				local c = string.sub(w, j, j)
				flags[SHORT[c] or c] = true
			end
		else
			table.insert(positional, w)
		end
		i += 1
	end
	return { flags = flags, positional = positional }
end

local function build(command: string, parsed: Parsed, launcher: string, wrapper: string?): Invocation
	local flags = parsed.flags
	local function str(name: string): string?
		local v = flags[name]
		return if type(v) == "string" and v ~= "" then v else nil
	end
	return table.freeze({
		command = command,
		flags = table.freeze(flags),
		positional = table.freeze(parsed.positional),
		authId = str("authid"),
		project = str("project"),
		interactive = flags.interactive == true,
		help = flags.help == true,
		launcher = launcher,
		viaWrapper = wrapper,
	})
end

-- `words[from]` onward is `[global options] <command> [options]`.
local function direct(words: { string }, from: number, launcher: string): Invocation?
	local i = from
	local lead: { string } = {}
	while i <= #words and string.sub(words[i], 1, 1) == "-" do
		table.insert(lead, words[i])
		i += 1
	end
	local command = words[i]
	if command == nil or not Commands.isKnown(command) then
		return nil
	end
	local rest = table.clone(lead)
	table.move(words, i + 1, #words, #rest + 1, rest)
	return build(command, parseOptions(rest, 1), launcher, nil)
end

local function isPackage(word: string): boolean
	return string.match(word, "^@oracle/suitecloud%-cli") ~= nil
		and not string.match(word, "^@oracle/suitecloud%-cli[^@]")
end

local function viaNpx(words: { string }): Invocation?
	local i = 2
	while i <= #words do
		local w = words[i]
		if NPX_VALUE[w] then
			i += 2
		elseif string.sub(w, 1, 1) == "-" then
			i += 1
		else
			break
		end
	end
	local pkg = words[i]
	if pkg == "suitecloud" then
		return direct(words, i + 1, "npx suitecloud")
	elseif pkg and isPackage(pkg) then
		return direct(words, i + 1, "npx @oracle/suitecloud-cli")
	end
	return nil
end

-- `suitecloud ...`, `npx ...` or, as Tern reports `npx @oracle/suitecloud-cli`
-- runs, the package's basename as the program (`suitecloud-cli[@3.2.0]`).
local function launched(words: { string }): Invocation?
	local first = words[1]
	if first == nil then
		return nil
	end
	local base = basename(first)
	if base == "suitecloud" then
		return direct(words, 2, "suitecloud")
	elseif base == "npx" then
		return viaNpx(words)
	elseif isPackage(first) or base == "suitecloud-cli" or string.match(base, "^suitecloud%-cli@") then
		return direct(words, 2, "npx @oracle/suitecloud-cli")
	end
	return nil
end

local function startsWith(words: { string }, prefix: { string }): boolean
	if #prefix == 0 or #words < #prefix then
		return false
	end
	for i, p in prefix do
		local w = words[i]
		if i == 1 and not string.find(p, "/", 1, true) then
			w = basename(w)
		end
		if w ~= p then
			return false
		end
	end
	return true
end

local function withoutAssignments(words: { string }): { string }
	local i = 1
	while i <= #words and string.match(words[i], "^[%a_][%w_]*=") do
		i += 1
	end
	return table.move(words, i, #words, 1, {})
end

local function viaWrapper(candidates: { { string } }, wrappers: { Wrapper }): Invocation?
	local best: Wrapper? = nil
	local bestWords: { string }? = nil
	local bestLen = 0
	for _, w in wrappers do
		local prefix = M.words(w.prefix)
		if #prefix <= bestLen then
			continue
		end
		for _, words in candidates do
			if startsWith(words, prefix) then
				best, bestWords, bestLen = w, words, #prefix
				break
			end
		end
	end
	if best == nil or bestWords == nil then
		return nil
	end
	return build(best.command, parseOptions(bestWords, bestLen + 1), best.prefix, best.prefix)
end

-- The SuiteCloud command of a lensed run, or nil when it is not one. Tern
-- reports `npx [opts] suitecloud x` with program `suitecloud`; the typed
-- line still shows the launcher, so it is read first.
function M.parse(run: Run, wrappers: { Wrapper }?): Invocation?
	local words: { string } = { run.program }
	table.move(run.args, 1, #run.args, 2, words)
	local candidates: { { string } } = {}
	for _, line in { run.line, run.typed } do
		if line and line ~= "" then
			table.insert(candidates, withoutAssignments(M.words(line)))
		end
	end
	table.insert(candidates, words)
	if wrappers and #wrappers > 0 then
		local wrapped = viaWrapper(candidates, wrappers)
		if wrapped then
			return wrapped
		end
	end
	for _, c in candidates do
		local inv = launched(c)
		if inv then
			return inv
		end
	end
	return nil
end

-- Interactive runs prompt and help prints usage: neither has a result to
-- render.
function M.renders(inv: Invocation): boolean
	return not inv.interactive and not inv.help
end

local function quote(s: string): string
	if string.match(s, "^[%w%._/:@%-=+,]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- The server-side validation of the same project, as a command to paste. A
-- wrapper's own flags mean nothing to suitecloud, so wrapped runs get the
-- plain CLI form (to run in the project folder).
function M.serverValidate(inv: Invocation): string
	local launcher = if inv.viaWrapper then "suitecloud" else inv.launcher
	local parts = { launcher, "project:validate", "--server" }
	local asv = inv.flags.accountspecificvalues
	if inv.viaWrapper == nil and type(asv) == "string" then
		table.insert(parts, "--accountspecificvalues")
		table.insert(parts, quote(asv))
	end
	return table.concat(parts, " ")
end

return table.freeze(M)
