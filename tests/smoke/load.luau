--!nonstrict
-- Loads the plugin's two halves from the generated bundle (tests/smoke/run.sh)
-- against the strict stub `tern` and checks the manifest: every [[lenses]]
-- and [[blocks]] id is defined by the host half, and nothing undeclared is.
-- Extra module paths given as arguments are loaded after the entries.

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

local host = newVm("host")
local window = newVm("window")
host.load("plugin/host.luau")
window.load("plugin/window.luau")

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
for _, p in problems do
	print("PROBLEM " .. p)
end
if #problems > 0 then
	error(string.format("smoke: %d problem(s)", #problems), 0)
end
print("smoke: ok")
return nil
