--!nonstrict
-- A strict stand-in for the `tern` global, one per plugin half. Every API the
-- installed tern.d.luau declares exists here; reading any other key raises,
-- and an API used in the half Tern does not offer it in raises too, so the
-- smoke run catches typos and wrong-half calls at load time. Effects are
-- recorded, never performed: no process runs, no request is sent, no file
-- is written.

local json = require("../lib/json")

export type Record = {
	lenses: { [string]: any },
	blocks: { [string]: any },
	commands: { [string]: any },
	hooks: { [string]: { any } },
	links: { any },
	opens: { any },
	status: { any },
	processes: { { string } },
	fetches: { string },
	timers: number,
	writes: { string },
}

local M = {}

local function strict(path: string, t: { [string]: any }): any
	return setmetatable(t, {
		__index = function(_, key)
			error(
				string.format("smoke: tern.%s%s is not stubbed", if path == "" then "" else path .. ".", tostring(key)),
				2
			)
		end,
	})
end

local function wrongHalf(name: string, ctx: string): () -> ()
	return function()
		error(string.format("smoke: tern.%s is not available in the %s half", name, ctx), 2)
	end
end

local function encode(v: any): string
	local tv = type(v)
	if tv == "nil" then
		return "null"
	elseif tv == "boolean" or tv == "number" then
		return tostring(v)
	elseif tv == "string" then
		return string.format("%q", v)
	elseif tv == "table" then
		if #v > 0 or next(v) == nil then
			local parts = {}
			for i, item in ipairs(v) do
				parts[i] = encode(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in v do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)
		local parts = {}
		for i, k in keys do
			parts[i] = string.format("%q:%s", k, encode(v[k]))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("smoke: cannot encode " .. tv)
end

local function awaitable(kind: string): any
	return { kind = kind, id = 0, next = function() end }
end

local function node(k: string, p: any?, c: any?): any
	return { k = k, p = p, c = c }
end

function M.new(context: "host" | "window"): (any, Record)
	local rec: Record = {
		lenses = {},
		blocks = {},
		commands = {},
		hooks = {},
		links = {},
		opens = {},
		status = {},
		processes = {},
		fetches = {},
		timers = 0,
		writes = {},
	}
	local host = context == "host"
	local window = context == "window"
	local kv: { [string]: any } = {}

	local function hostOnly<F>(name: string, fn: F): F
		return if host then fn else wrongHalf(name, context) :: any
	end
	local function windowOnly<F>(name: string, fn: F): F
		return if window then fn else wrongHalf(name, context) :: any
	end

	local ui = strict("ui", {})
	for _, k in
		{
			"text",
			"col",
			"lines",
			"row",
			"card",
			"section",
			"rule",
			"badge",
			"kv",
			"table",
			"tree",
			"list",
			"code",
			"diff",
			"md",
			"meter",
			"progress",
			"bars",
			"spark",
			"ansi",
			"diagnostic",
			"test_summary",
			"overflow",
		}
	do
		ui[k] = function(...)
			return node(k, { ... })
		end
	end
	ui.span = function(t, s)
		return { t = t, s = s }
	end
	ui.link = function(t, href, s)
		return { t = t, s = s, href = href }
	end
	ui.path = function(p)
		return { t = p }
	end
	ui.meter_cell = function(v)
		return { meter = { value = v } }
	end
	ui.meter_parts_cell = function()
		return { meter = {} }
	end
	ui.node = node
	ui.el = function(tag, p, c)
		local props = table.clone(p or {})
		props.tag = tag
		return node("el", props, c)
	end

	local tern = strict("", {
		context = context,
		plugin = strict(
			"plugin",
			{ id = "tern-netsuite", name = "Tern NetSuite", dir = "/smoke/plugin", data = "/smoke/data" }
		),
		runtime = strict("runtime", { os = "macos", jit = false }),
		log = strict("log", {
			debug = function() end,
			info = function() end,
			warn = function() end,
			error = function() end,
		}),
		json = strict("json", {
			encode = function(v)
				return encode(v)
			end,
			decode = json.decode,
			array = function(t)
				return t or {}
			end,
			null = json.null,
		}),
		base64 = strict("base64", {
			encode = function()
				return ""
			end,
			decode = function()
				return ""
			end,
		}),
		now = function()
			return 0
		end,
		getenv = function(name)
			return if name == "HOME" then "/smoke/home" else nil
		end,
		timer = function()
			rec.timers += 1
			return { cancel = function() end }
		end,
		sleep = function()
			return awaitable("sleep")
		end,
		kv = strict("kv", {
			get = function(k)
				return kv[k]
			end,
			set = function(k, v)
				kv[k] = v
			end,
		}),
		secrets = strict("secrets", {
			get = windowOnly("secrets.get", function()
				return awaitable("secrets.get")
			end),
			set = windowOnly("secrets.set", function()
				return awaitable("secrets.set")
			end),
		}),
		fs = strict("fs", {
			read = function(path)
				error("smoke: no such file " .. tostring(path))
			end,
			write = function(path)
				table.insert(rec.writes, path)
			end,
			list = function()
				return {}
			end,
			exists = function()
				return false
			end,
			mkdir = function() end,
			remove = function(path)
				table.insert(rec.writes, path)
			end,
		}),
		process = strict("process", {
			run = function(argv, ...)
				table.insert(rec.processes, argv)
				local n = select("#", ...)
				local last = if n > 0 then select(n, ...) else nil
				return if type(last) == "function" then nil else awaitable("process.run")
			end,
		}),
		fetch = function(url, ...)
			table.insert(rec.fetches, url)
			local n = select("#", ...)
			local last = if n > 0 then select(n, ...) else nil
			return if type(last) == "function" then nil else awaitable("fetch")
		end,
		ui = ui,
		parse = strict("parse", {
			columns = function()
				return nil
			end,
			packed = function()
				return {}
			end,
			json_tree = function()
				return nil
			end,
			location = function()
				return nil
			end,
			size = function()
				return nil
			end,
		}),
		block = strict("block", {
			define = hostOnly("block.define", function(id, def)
				assert(type(id) == "string", "block id must be a string")
				assert(rec.blocks[id] == nil, "block defined twice: " .. id)
				assert(
					type(def.init) == "function" and type(def.view) == "function",
					"block " .. id .. " needs init and view"
				)
				rec.blocks[id] = def
			end),
		}),
		lens = strict("lens", {
			define = hostOnly("lens.define", function(id, def)
				assert(type(id) == "string", "lens id must be a string")
				assert(rec.lenses[id] == nil, "lens defined twice: " .. id)
				for _, k in { "open", "line", "finish", "view" } do
					assert(type(def[k]) == "function", "lens " .. id .. " needs " .. k)
				end
				rec.lenses[id] = def
			end),
		}),
		pane = strict("pane", {
			write = hostOnly("pane.write", function() end),
			list = hostOnly("pane.list", function()
				return {}
			end),
		}),
		on = function(name, fn)
			assert(type(fn) == "function", "tern.on needs a function")
			rec.hooks[name] = rec.hooks[name] or {}
			table.insert(rec.hooks[name], fn)
		end,
		command = windowOnly("command", function(def)
			assert(type(def.id) == "string" and type(def.run) == "function", "command needs id and run")
			assert(rec.commands[def.id] == nil, "command defined twice: " .. def.id)
			rec.commands[def.id] = def
		end),
		bind = windowOnly("bind", function() end),
		override = windowOnly("override", function() end),
		route = strict("route", {
			open = windowOnly("route.open", function(fn)
				table.insert(rec.opens, fn)
			end),
			link = windowOnly("route.link", function(fn)
				table.insert(rec.links, fn)
			end),
		}),
		chrome = strict("chrome", {
			tab_title = windowOnly("chrome.tab_title", function() end),
			window_title = windowOnly("chrome.window_title", function() end),
			status = windowOnly("chrome.status", function(fn)
				table.insert(rec.status, fn)
			end),
			refresh = windowOnly("chrome.refresh", function() end),
		}),
		css = windowOnly("css", function() end),
		carly = strict("carly", {
			export = windowOnly("carly.export", function() end),
			context = windowOnly("carly.context", function() end),
			schedule = windowOnly("carly.schedule", function()
				return 0
			end),
			tasks = windowOnly("carly.tasks", function()
				return {}
			end),
			cancel = windowOnly("carly.cancel", function()
				return false
			end),
			on_canvas = windowOnly("carly.on_canvas", function() end),
		}),
	})
	return tern, rec
end

return M
