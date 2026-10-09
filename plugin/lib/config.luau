--!strict
-- The user's config file ($XDG_CONFIG_HOME/tern-netsuite/config.json), parsed
-- and validated. A bad value never fails the load: it falls back to its
-- default (or the bad entry is dropped) with a diagnostic naming the key
-- path, so a typo can never take the plugin down or weaken a safety default.

local Commands = require("./sdf/commands")
local HistorySettings = require("./history/settings")

local M = {}

M.SCHEMA_VERSION = 1
M.RELATIVE_PATH = "tern-netsuite/config.json"

export type Wrapper = { prefix: string, command: string }

export type Account = {
	id: string,
	account_id: string,
	label: string?,
	-- nil: inferred from account_id (lib/account/classify.luau).
	production: boolean?,
	auth_ids: { string },
}

export type Restlet = {
	script: string,
	deploy: string,
	query_field: string,
	params_field: string,
	-- Dotted path to the row array in the JSON response.
	rows_path: string,
	-- Extra string fields merged into every request body.
	extra: { [string]: string },
}

export type Auth = "tba" | "oauth2_m2m"
export type Transport = "rest" | "restlet"

export type Connection = {
	id: string,
	account: string,
	auth: Auth,
	transport: Transport,
	read_only: boolean,
	timeout_ms: number,
	restlet: Restlet?,
}

export type CheckKind = "count" | "freshness"

export type Check = {
	id: string,
	label: string,
	connection: string,
	kind: CheckKind,
	query: string,
	warn_at: number?,
	error_at: number?,
	max_age_minutes: number?,
}

export type Config = {
	schema_version: number,
	general: { native_default: boolean, max_lines: number, max_capture_bytes: number },
	suitecloud: { program: string, timeout_ms: number },
	lens: { wrappers: { Wrapper } },
	projects: { roots: { string }, follow_symlinks: boolean, max_files: number },
	accounts: { Account },
	guard: { confirm_production: boolean, typed_confirmation: boolean, commands: { string }, timeout_s: number },
	connections: { Connection },
	monitor: {
		poll_seconds: number,
		log_poll_seconds: number,
		log_title_json: boolean,
		script_errors: { enabled: boolean, hour_error_at: number, day_warn_at: number },
		checks: { Check },
	},
	status: { enabled: boolean },
	scaffold: { templates_dir: string? },
	history: HistorySettings.Settings,
}

export type Level = "error" | "warning" | "info"

export type Diagnostic = {
	level: Level,
	-- Dotted key path ("guard.commands[2]"); "" is the whole file.
	path: string,
	message: string,
}

type Ctx = { diags: { Diagnostic } }

local function freezeDeep<T>(t: T): T
	for _, v in t :: any do
		if type(v) == "table" and not table.isfrozen(v) then
			freezeDeep(v)
		end
	end
	return table.freeze(t :: any) :: any
end

function M.defaults(): Config
	local cfg: Config = {
		schema_version = M.SCHEMA_VERSION,
		general = { native_default = true, max_lines = 20000, max_capture_bytes = 8388608 },
		suitecloud = { program = "suitecloud", timeout_ms = 600000 },
		lens = { wrappers = {} },
		projects = { roots = {}, follow_symlinks = true, max_files = 5000 },
		accounts = {},
		guard = {
			confirm_production = true,
			typed_confirmation = true,
			commands = { "project:deploy", "file:upload" },
			timeout_s = 600,
		},
		connections = {},
		monitor = {
			poll_seconds = 120,
			log_poll_seconds = 15,
			log_title_json = true,
			script_errors = { enabled = true, hour_error_at = 1, day_warn_at = 1 },
			checks = {},
		},
		status = { enabled = true },
		scaffold = {},
		history = HistorySettings.defaults(),
	}
	return freezeDeep(cfg)
end

function M.path(env: { XDG_CONFIG_HOME: string?, HOME: string? }): string?
	local xdg = env.XDG_CONFIG_HOME
	if xdg and xdg ~= "" then
		return xdg .. "/" .. M.RELATIVE_PATH
	end
	local home = env.HOME
	if home and home ~= "" then
		return home .. "/.config/" .. M.RELATIVE_PATH
	end
	return nil
end

-- Shapes ----------------------------------------------------------------------

local function isObject(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	for k in v do
		if type(k) ~= "string" then
			return false
		end
	end
	return true
end

local function isArray(v: any): boolean
	if type(v) ~= "table" then
		return false
	end
	local n = 0
	for k in v do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #v
end

local function isInteger(v: any): boolean
	return type(v) == "number" and v == math.floor(v) and math.abs(v) ~= math.huge
end

local function blank(s: string): boolean
	return string.find(s, "^%s*$") ~= nil
end

local function report(ctx: Ctx, level: Level, path: string, message: string)
	table.insert(ctx.diags, { level = level, path = path, message = message })
end

local function join(path: string, key: string): string
	return if path == "" then key else path .. "." .. key
end

-- Warns about keys a section does not know (typos would silently do nothing).
local function unknownKeys(ctx: Ctx, obj: { [string]: any }, path: string, known: { string })
	local set: { [string]: boolean } = {}
	for _, k in known do
		set[k] = true
	end
	local extra: { string } = {}
	for k in obj do
		if not set[k] then
			table.insert(extra, k)
		end
	end
	table.sort(extra)
	for _, k in extra do
		report(ctx, "warning", join(path, k), "unknown key; it is ignored")
	end
end

-- Scalars ---------------------------------------------------------------------

local function bool(ctx: Ctx, v: any, path: string, default: boolean): boolean
	if v == nil then
		return default
	end
	if type(v) ~= "boolean" then
		report(ctx, "error", path, "must be true or false; using the default " .. tostring(default))
		return default
	end
	return v
end

local function int(ctx: Ctx, v: any, path: string, default: number, min: number, max: number): number
	if v == nil then
		return default
	end
	if not isInteger(v) or v < min or v > max then
		report(
			ctx,
			"error",
			path,
			string.format("must be an integer from %d to %d; using the default %d", min, max, default)
		)
		return default
	end
	return v
end

local function str(ctx: Ctx, v: any, path: string, default: string?): string?
	if v == nil then
		return default
	end
	if type(v) ~= "string" or blank(v) then
		report(ctx, "error", path, "must be a non-empty string" .. (if default then "; using the default" else ""))
		return default
	end
	return v
end

local function enum<T>(ctx: Ctx, v: any, path: string, default: T, options: { string }): T?
	if v == nil then
		return default
	end
	if type(v) == "string" and table.find(options, v) then
		return v :: any
	end
	report(ctx, "error", path, "must be one of " .. table.concat(options, ", "))
	return nil
end

local function strList(ctx: Ctx, v: any, path: string, default: { string }, valid: ((string) -> boolean)?): { string }
	if v == nil then
		return table.clone(default)
	end
	if not isArray(v) then
		report(ctx, "error", path, "must be an array of strings; using the default")
		return table.clone(default)
	end
	local out: { string } = {}
	for i, item in v do
		local p = string.format("%s[%d]", path, i)
		if type(item) ~= "string" or blank(item) then
			report(ctx, "error", p, "must be a non-empty string; entry dropped")
		elseif valid and not valid(item) then
			report(ctx, "error", p, string.format("%q is not allowed here; entry dropped", item))
		else
			table.insert(out, item)
		end
	end
	return out
end

-- A typo never unguards a default command: any rejected entry brings the
-- defaults back alongside the valid entries. Only an explicit [] guards none.
local function guardCommands(ctx: Ctx, v: any, default: { string }): { string }
	if isArray(v) and next(v) == nil then
		report(ctx, "warning", "guard.commands", "is empty: no SuiteCloud command is guarded")
		return {}
	end
	local before = #ctx.diags
	local valid = strList(ctx, v, "guard.commands", default, Commands.isKnown)
	if #ctx.diags == before then
		return valid
	end
	for _, c in default do
		if not table.find(valid, c) then
			table.insert(valid, c)
		end
	end
	return valid
end

local function section(ctx: Ctx, v: any, path: string, known: { string }): { [string]: any }
	if v == nil then
		return {}
	end
	if not isObject(v) then
		report(ctx, "error", path, "must be an object; using the defaults")
		return {}
	end
	unknownKeys(ctx, v, path, known)
	return v
end

-- Each item of a record array is validated by `item`, which returns nil to drop it.
local function records<T>(ctx: Ctx, v: any, path: string, item: (any, string) -> T?): { T }
	if v == nil then
		return {}
	end
	if not isArray(v) then
		report(ctx, "error", path, "must be an array; using none")
		return {}
	end
	local out: { T } = {}
	for i, raw in v do
		local p = string.format("%s[%d]", path, i)
		if not isObject(raw) then
			report(ctx, "error", p, "must be an object; entry dropped")
		else
			local value = item(raw, p)
			if value ~= nil then
				table.insert(out, value)
			end
		end
	end
	return out
end

local function required(ctx: Ctx, v: any, path: string): string?
	if v == nil then
		report(ctx, "error", path, "is required; entry dropped")
		return nil
	end
	return str(ctx, v, path, nil)
end

-- Sections --------------------------------------------------------------------

local function wrappers(ctx: Ctx, v: any, path: string): { Wrapper }
	return records(ctx, v, path, function(raw: any, p: string): Wrapper?
		unknownKeys(ctx, raw, p, { "prefix", "command" })
		local prefix = required(ctx, raw.prefix, p .. ".prefix")
		local command = required(ctx, raw.command, p .. ".command")
		if prefix == nil or command == nil then
			return nil
		end
		if not Commands.isKnown(command) then
			report(
				ctx,
				"error",
				p .. ".command",
				string.format("%q is not a SuiteCloud command; entry dropped", command)
			)
			return nil
		end
		return { prefix = (string.gsub(prefix, "^%s+", "")), command = command }
	end)
end

local function accounts(ctx: Ctx, v: any, path: string): { Account }
	local ids: { [string]: boolean } = {}
	local accountIds: { [string]: string } = {}
	local authOwners: { [string]: string } = {}
	return records(ctx, v, path, function(raw: any, p: string): Account?
		unknownKeys(ctx, raw, p, { "id", "account_id", "label", "production", "auth_ids" })
		local id = required(ctx, raw.id, p .. ".id")
		local accountId = required(ctx, raw.account_id, p .. ".account_id")
		if id == nil or accountId == nil then
			return nil
		end
		if ids[id] then
			report(ctx, "error", p .. ".id", string.format("duplicate account id %q; entry dropped", id))
			return nil
		end
		local upper = string.upper(accountId)
		if accountIds[upper] then
			report(
				ctx,
				"error",
				p .. ".account_id",
				string.format("account %q already configured as %q; entry dropped", upper, accountIds[upper])
			)
			return nil
		end
		ids[id] = true
		accountIds[upper] = id
		local production: boolean? = nil
		if raw.production ~= nil then
			if type(raw.production) == "boolean" then
				production = raw.production
			else
				production = true
				report(ctx, "error", p .. ".production", "must be true or false; treated as true (production)")
			end
		end
		local auth: { string } = {}
		for i, a in strList(ctx, raw.auth_ids, p .. ".auth_ids", {}) do
			local owner = authOwners[a]
			if owner then
				report(
					ctx,
					"error",
					string.format("%s.auth_ids[%d]", p, i),
					string.format("auth id %q already belongs to account %q; entry dropped", a, owner)
				)
			else
				authOwners[a] = id
				table.insert(auth, a)
			end
		end
		return {
			id = id,
			account_id = string.upper(accountId),
			label = str(ctx, raw.label, p .. ".label", nil),
			production = production,
			auth_ids = auth,
		}
	end)
end

local function restlet(ctx: Ctx, raw: any, p: string): Restlet?
	if not isObject(raw) then
		report(ctx, "error", p, "the restlet transport needs an object with script and deploy; entry dropped")
		return nil
	end
	unknownKeys(ctx, raw, p, { "script", "deploy", "query_field", "params_field", "rows_path", "extra" })
	local script = required(ctx, raw.script, p .. ".script")
	local deploy = required(ctx, raw.deploy, p .. ".deploy")
	if script == nil or deploy == nil then
		return nil
	end
	local extra: { [string]: string } = {}
	if raw.extra ~= nil then
		if isObject(raw.extra) then
			for k, val in raw.extra do
				if type(val) == "string" then
					extra[k] = val
				else
					report(ctx, "error", p .. ".extra." .. k, "must be a string; field dropped")
				end
			end
		else
			report(ctx, "error", p .. ".extra", "must be an object of strings; ignored")
		end
	end
	return {
		script = script,
		deploy = deploy,
		query_field = str(ctx, raw.query_field, p .. ".query_field", "query") :: string,
		params_field = str(ctx, raw.params_field, p .. ".params_field", "params") :: string,
		rows_path = str(ctx, raw.rows_path, p .. ".rows_path", "rows") :: string,
		extra = extra,
	}
end

local function connections(ctx: Ctx, v: any, path: string, accountIds: { [string]: boolean }): { Connection }
	local ids: { [string]: boolean } = {}
	return records(ctx, v, path, function(raw: any, p: string): Connection?
		unknownKeys(ctx, raw, p, { "id", "account", "auth", "transport", "read_only", "timeout_ms", "restlet" })
		local id = required(ctx, raw.id, p .. ".id")
		local account = required(ctx, raw.account, p .. ".account")
		if id == nil or account == nil then
			return nil
		end
		if ids[id] then
			report(ctx, "error", p .. ".id", string.format("duplicate connection id %q; entry dropped", id))
			return nil
		end
		-- Credentials live in tern.secrets as `<id>.<field>`; names must match
		-- [a-z0-9][a-z0-9._-]{0,63} and the longest field is "consumer_secret".
		if string.find(id, "^[a-z0-9][a-z0-9%._%-]*$") == nil or #id > 48 then
			report(
				ctx,
				"error",
				p .. ".id",
				"must be lower-case letters, digits, '.', '_' or '-' (at most 48 characters), "
					.. "as it names keychain entries; entry dropped"
			)
			return nil
		end
		if not accountIds[account] then
			report(ctx, "error", p .. ".account", string.format("no account with id %q; entry dropped", account))
			return nil
		end
		local auth = enum(ctx, raw.auth, p .. ".auth", "tba", { "tba", "oauth2_m2m" })
		local transport = enum(ctx, raw.transport, p .. ".transport", "rest", { "rest", "restlet" })
		if auth == nil or transport == nil then
			return nil
		end
		local rl: Restlet? = nil
		if transport == "restlet" then
			rl = restlet(ctx, raw.restlet, p .. ".restlet")
			if rl == nil then
				return nil
			end
		elseif raw.restlet ~= nil then
			report(ctx, "warning", p .. ".restlet", "ignored: transport is not restlet")
		end
		ids[id] = true
		return {
			id = id,
			account = account,
			auth = auth :: Auth,
			transport = transport :: Transport,
			read_only = bool(ctx, raw.read_only, p .. ".read_only", true),
			timeout_ms = int(ctx, raw.timeout_ms, p .. ".timeout_ms", 30000, 1000, 300000),
			restlet = rl,
		}
	end)
end

local function checks(ctx: Ctx, v: any, path: string, connectionIds: { [string]: boolean }): { Check }
	local ids: { [string]: boolean } = {}
	return records(ctx, v, path, function(raw: any, p: string): Check?
		unknownKeys(
			ctx,
			raw,
			p,
			{ "id", "label", "connection", "kind", "query", "warn_at", "error_at", "max_age_minutes" }
		)
		local id = required(ctx, raw.id, p .. ".id")
		local connection = required(ctx, raw.connection, p .. ".connection")
		local query = required(ctx, raw.query, p .. ".query")
		if id == nil or connection == nil or query == nil then
			return nil
		end
		if ids[id] then
			report(ctx, "error", p .. ".id", string.format("duplicate check id %q; entry dropped", id))
			return nil
		end
		if not connectionIds[connection] then
			report(
				ctx,
				"error",
				p .. ".connection",
				string.format("no connection with id %q; entry dropped", connection)
			)
			return nil
		end
		local kind = enum(ctx, raw.kind, p .. ".kind", "count", { "count", "freshness" })
		if kind == nil then
			return nil
		end
		local function optInt(key: string): number?
			local val = raw[key]
			if val == nil then
				return nil
			end
			if not isInteger(val) or val < 0 then
				report(ctx, "error", p .. "." .. key, "must be a non-negative integer; ignored")
				return nil
			end
			return val
		end
		local maxAge = optInt("max_age_minutes")
		if kind == "freshness" and maxAge == nil then
			report(ctx, "error", p .. ".max_age_minutes", "a freshness check needs max_age_minutes; entry dropped")
			return nil
		end
		ids[id] = true
		return {
			id = id,
			label = str(ctx, raw.label, p .. ".label", id) :: string,
			connection = connection,
			kind = kind :: CheckKind,
			query = query,
			warn_at = optInt("warn_at"),
			error_at = optInt("error_at"),
			max_age_minutes = maxAge,
		}
	end)
end

-- Parse -----------------------------------------------------------------------

local TOP = {
	"schema_version",
	"general",
	"suitecloud",
	"lens",
	"projects",
	"accounts",
	"guard",
	"connections",
	"monitor",
	"status",
	"scaffold",
	"history",
}

local function build(ctx: Ctx, root: { [string]: any }): Config
	local d = M.defaults()
	unknownKeys(ctx, root, "", TOP)

	if root.schema_version ~= nil then
		if not isInteger(root.schema_version) then
			report(ctx, "error", "schema_version", "must be an integer")
		elseif root.schema_version > M.SCHEMA_VERSION then
			report(
				ctx,
				"warning",
				"schema_version",
				string.format(
					"written for schema %d; this plugin knows %d, newer keys are ignored",
					root.schema_version,
					M.SCHEMA_VERSION
				)
			)
		end
	end

	local g = section(ctx, root.general, "general", { "native_default", "max_lines", "max_capture_bytes" })
	local sc = section(ctx, root.suitecloud, "suitecloud", { "program", "timeout_ms" })
	local ln = section(ctx, root.lens, "lens", { "wrappers" })
	local pr = section(ctx, root.projects, "projects", { "roots", "follow_symlinks", "max_files" })
	local gd =
		section(ctx, root.guard, "guard", { "confirm_production", "typed_confirmation", "commands", "timeout_s" })
	local mo = section(
		ctx,
		root.monitor,
		"monitor",
		{ "poll_seconds", "log_poll_seconds", "log_title_json", "script_errors", "checks" }
	)
	local se = section(ctx, mo.script_errors, "monitor.script_errors", { "enabled", "hour_error_at", "day_warn_at" })
	local dse = d.monitor.script_errors
	local st = section(ctx, root.status, "status", { "enabled" })
	local sf = section(ctx, root.scaffold, "scaffold", { "templates_dir" })

	local accts = accounts(ctx, root.accounts, "accounts")
	local accountIds: { [string]: boolean } = {}
	for _, a in accts do
		accountIds[a.id] = true
	end
	local conns = connections(ctx, root.connections, "connections", accountIds)
	local connectionIds: { [string]: boolean } = {}
	for _, c in conns do
		connectionIds[c.id] = true
	end

	return {
		schema_version = M.SCHEMA_VERSION,
		general = {
			native_default = bool(ctx, g.native_default, "general.native_default", d.general.native_default),
			max_lines = int(ctx, g.max_lines, "general.max_lines", d.general.max_lines, 100, 1000000),
			max_capture_bytes = int(
				ctx,
				g.max_capture_bytes,
				"general.max_capture_bytes",
				d.general.max_capture_bytes,
				65536,
				67108864
			),
		},
		suitecloud = {
			program = str(ctx, sc.program, "suitecloud.program", d.suitecloud.program) :: string,
			timeout_ms = int(ctx, sc.timeout_ms, "suitecloud.timeout_ms", d.suitecloud.timeout_ms, 1000, 3600000),
		},
		lens = { wrappers = wrappers(ctx, ln.wrappers, "lens.wrappers") },
		projects = {
			roots = strList(ctx, pr.roots, "projects.roots", d.projects.roots),
			follow_symlinks = bool(ctx, pr.follow_symlinks, "projects.follow_symlinks", d.projects.follow_symlinks),
			max_files = int(ctx, pr.max_files, "projects.max_files", d.projects.max_files, 10, 200000),
		},
		accounts = accts,
		guard = {
			confirm_production = bool(ctx, gd.confirm_production, "guard.confirm_production", true),
			typed_confirmation = bool(ctx, gd.typed_confirmation, "guard.typed_confirmation", true),
			commands = guardCommands(ctx, gd.commands, d.guard.commands),
			timeout_s = int(ctx, gd.timeout_s, "guard.timeout_s", d.guard.timeout_s, 10, 3600),
		},
		connections = conns,
		monitor = {
			poll_seconds = int(ctx, mo.poll_seconds, "monitor.poll_seconds", d.monitor.poll_seconds, 30, 3600),
			log_poll_seconds = int(
				ctx,
				mo.log_poll_seconds,
				"monitor.log_poll_seconds",
				d.monitor.log_poll_seconds,
				5,
				600
			),
			log_title_json = bool(ctx, mo.log_title_json, "monitor.log_title_json", d.monitor.log_title_json),
			script_errors = {
				enabled = bool(ctx, se.enabled, "monitor.script_errors.enabled", dse.enabled),
				hour_error_at = int(
					ctx,
					se.hour_error_at,
					"monitor.script_errors.hour_error_at",
					dse.hour_error_at,
					1,
					1000000
				),
				day_warn_at = int(
					ctx,
					se.day_warn_at,
					"monitor.script_errors.day_warn_at",
					dse.day_warn_at,
					1,
					1000000
				),
			},
			checks = checks(ctx, mo.checks, "monitor.checks", connectionIds),
		},
		status = { enabled = bool(ctx, st.enabled, "status.enabled", d.status.enabled) },
		scaffold = { templates_dir = str(ctx, sf.templates_dir, "scaffold.templates_dir", nil) },
		history = HistorySettings.parse(
			root.history,
			function(level: "error" | "warning", path: string, message: string)
				report(ctx, level, path, message)
			end
		),
	}
end

-- Parses the file text (nil = no file). Never raises.
function M.parse(text: string?, decode: (string) -> any): (Config, { Diagnostic })
	local ctx: Ctx = { diags = {} }
	if text == nil then
		return M.defaults(), ctx.diags
	end
	local ok, root = pcall(decode, text)
	if not ok then
		report(ctx, "error", "", "invalid JSON (" .. tostring(root) .. "); using the defaults for every setting")
		return M.defaults(), ctx.diags
	end
	if not isObject(root) or isArray(root) and next(root) ~= nil then
		report(ctx, "error", "", "the file must hold a JSON object; using the defaults for every setting")
		return M.defaults(), ctx.diags
	end
	return freezeDeep(build(ctx, root)), ctx.diags
end

return M
