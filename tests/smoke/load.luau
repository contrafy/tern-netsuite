--!nonstrict
-- Loads the plugin's two halves from the generated bundle (tests/smoke/run.sh)
-- against the strict stub `tern` and checks the manifest: every [[lenses]]
-- and [[blocks]] id is defined by the host half, and nothing undeclared is.
-- Extra module paths given as arguments are loaded after the entries.
--
-- It also keeps each half's load within BUDGET: Tern aborts a window half
-- whose load takes over 50 ms, and real Tern loads several times slower than
-- standalone luau.

local Stub = require("./stub")
local bundle = require("./.generated/bundle")

local sources: { [string]: string } = bundle.sources
-- Standard library fallback for the chunks' environments.
-- selene: allow(global_usage)
local GLOBALS = _G

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or "."
end

local function normalize(path: string): string
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			assert(#parts > 0, "require escapes the package: " .. path)
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return table.concat(parts, "/")
end

-- One module cache per half, like Tern's two VMs.
local function newVm(context: "host" | "window")
	local tern, rec = Stub.new(context)
	local cache: { [string]: any } = {}
	local loading: { [string]: boolean } = {}
	local load: (string) -> any

	local function resolve(from: string, spec: string): string
		assert(
			string.sub(spec, 1, 2) == "./" or string.sub(spec, 1, 3) == "../",
			string.format("%s: require %q is not relative", from, spec)
		)
		local base = normalize(dirname(from) .. "/" .. spec)
		if sources[base .. ".luau"] then
			return base .. ".luau"
		elseif sources[base .. "/init.luau"] then
			return base .. "/init.luau"
		end
		error(string.format("%s: require %q does not resolve inside plugin/", from, spec), 0)
	end

	function load(path: string): any
		if cache[path] ~= nil then
			return cache[path]
		end
		assert(not loading[path], "require cycle through " .. path)
		local src = sources[path]
		assert(src, "no such plugin module " .. path)
		local chunk, err = loadstring(src, "@" .. path)
		if chunk == nil then
			error(path .. ": " .. tostring(err), 0)
		end
		local env = setmetatable({
			tern = tern,
			require = function(spec: string)
				return load(resolve(path, spec))
			end,
		}, { __index = GLOBALS })
		setfenv(chunk, env)
		loading[path] = true
		local ok, result = pcall(chunk)
		loading[path] = nil
		if not ok then
			error(string.format("loading %s (%s half) failed: %s", path, context, tostring(result)), 0)
		end
		cache[path] = if result == nil then true else result
		return result
	end

	return {
		load = load,
		rec = rec,
		loaded = function(path: string): boolean
			return cache[path] ~= nil
		end,
		-- Modules loaded so far and their total source size in KiB.
		size = function(): (number, number)
			local n, bytes = 0, 0
			for path in cache do
				n += 1
				bytes += #sources[path]
			end
			return n, bytes / 1024
		end,
	}
end

local function sortedKeys(t: { [string]: any }): { string }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

local function sameSet(what: string, declared: { string }, defined: { [string]: any }): { string }
	local problems = {}
	local seen: { [string]: boolean } = {}
	for _, id in declared do
		seen[id] = true
		if defined[id] == nil then
			table.insert(problems, string.format("plugin.toml %s %q has no tern.%s.define", what, id, what))
		end
	end
	for _, id in sortedKeys(defined) do
		if not seen[id] then
			table.insert(problems, string.format("tern.%s.define(%q) is not declared in plugin.toml", what, id))
		end
	end
	return problems
end

local extra: { string } = {}
for _, arg in { ... } do
	if type(arg) == "string" and string.sub(arg, -5) == ".luau" then
		table.insert(extra, (string.gsub(arg, "^%./", "")))
	end
end

-- Load budgets per half: time (best of RUNS fresh loads, each compiling every
-- module again, so one scheduling hiccup on a shared CI runner cannot fail
-- the check) and, for the window, the source size loaded, which does not vary
-- with the machine.
--
-- Tern 0.8.3 aborts a window half whose load takes over 50 ms; it does not
-- limit the host half's load. Real Tern costs about 0.1 ms per module plus
-- 0.16 ms per KiB of source on a busy machine: the window used to load 321 KiB
-- (9 ms here on an Apple M-series laptop, 35-40 ms and occasional aborts in
-- real Tern) and loads about 155 KiB now (4.5 ms here, 18-23 ms in real
-- Tern). The KiB budget catches a regression on any hardware; the window's
-- 15 ms leaves 3x headroom over that laptop for slower CI runners. The host
-- loads everything (19 ms here); its 60 ms only flags runaway growth.
local RUNS = 3
local BUDGET: { [string]: { ms: number, kib: number? } } = {
	host = { ms = 60 },
	window = { ms = 15, kib = 180 },
}

type Load = { vm: any, ms: number, modules: number, kib: number }

local function timedLoad(context: "host" | "window"): Load
	local first, best = nil, math.huge
	for _ = 1, RUNS do
		local vm = newVm(context)
		local started = os.clock()
		vm.load("plugin/" .. context .. ".luau")
		best = math.min(best, (os.clock() - started) * 1000)
		first = first or vm
	end
	local modules, kib = first.size()
	return { vm = first, ms = best, modules = modules, kib = kib }
end

local loads = { host = timedLoad("host"), window = timedLoad("window") }
local host, window = loads.host.vm, loads.window.vm

for _, path in extra do
	local vm = if string.find(path, "_window%.luau$") then window else host
	local already = vm.loaded(path)
	local mod = vm.load(path)
	if not already and type(mod) == "table" and type(mod.register) == "function" then
		mod.register()
	end
	print("loaded " .. path .. (if already then " (already loaded by the entry files)" else ""))
end

local problems = {}
for _, context in { "host", "window" } do
	local l, budget = loads[context], BUDGET[context]
	local over = {}
	if l.ms > budget.ms then
		table.insert(over, string.format("%.1f ms (best of %d) > %d ms", l.ms, RUNS, budget.ms))
	end
	if budget.kib and l.kib > budget.kib then
		table.insert(over, string.format("%d KiB of source > %d KiB", l.kib, budget.kib))
	end
	if #over > 0 then
		table.insert(
			problems,
			string.format(
				"the %s half's load is over budget (%s): require modules that registration does not need"
					.. " on first use (plugin/lib/lazy.luau)",
				context,
				table.concat(over, ", ")
			)
		)
	end
end
if #extra == 0 then
	for _, p in sameSet("lens", bundle.lenses, host.rec.lenses) do
		table.insert(problems, p)
	end
	for _, p in sameSet("block", bundle.blocks, host.rec.blocks) do
		table.insert(problems, p)
	end
	if #window.rec.links == 0 then
		table.insert(problems, "window half registered no route.link: tern-netsuite:// links would reach the OS")
	end
end

print(
	string.format(
		"host: %d lens(es) [%s], %d block(s) [%s], hooks [%s]",
		#sortedKeys(host.rec.lenses),
		table.concat(sortedKeys(host.rec.lenses), ", "),
		#sortedKeys(host.rec.blocks),
		table.concat(sortedKeys(host.rec.blocks), ", "),
		table.concat(sortedKeys(host.rec.hooks), ", ")
	)
)
print(
	string.format(
		"window: %d command(s) [%s], %d link route(s), %d status formatter(s), hooks [%s]",
		#sortedKeys(window.rec.commands),
		table.concat(sortedKeys(window.rec.commands), ", "),
		#window.rec.links,
		#window.rec.status,
		table.concat(sortedKeys(window.rec.hooks), ", ")
	)
)
for _, context in { "host", "window" } do
	local l, budget = loads[context], BUDGET[context]
	print(
		string.format(
			"%s load: %.1f ms best of %d (budget %d), %d modules, %d KiB%s",
			context,
			l.ms,
			RUNS,
			budget.ms,
			l.modules,
			l.kib,
			if budget.kib then string.format(" (budget %d)", budget.kib) else ""
		)
	)
end
for _, p in problems do
	print("PROBLEM " .. p)
end
if #problems > 0 then
	error(string.format("smoke: %d problem(s)", #problems), 0)
end
print("smoke: ok")
return nil
