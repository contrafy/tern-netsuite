--!strict
-- The config's `history` section. Config.parse calls `parse` for it and
-- stores the result as `config.history`; `of` falls back to the defaults
-- for a config parsed without that key. CI runs are off unless
-- `history.ci.workflow` names a workflow.

local M = {}

export type Ci = {
	-- gh program (name on PATH or absolute path).
	gh: string,
	-- Workflow file name or name, as `gh run list --workflow` takes it.
	workflow: string,
	limit: number,
	timeout_ms: number,
	-- How often the status-line segment re-asks gh.
	poll_seconds: number,
}

export type Settings = {
	-- Entries kept in history.jsonl; older ones are dropped.
	max_entries: number,
	ci: Ci?,
}

export type Report = (level: "error" | "warning", path: string, message: string) -> ()

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

local function unknown(raw: { [string]: any }, path: string, known: { string }, report: Report)
	local extra: { string } = {}
	for k in raw do
		if not table.find(known, k) then
			table.insert(extra, k)
		end
	end
	table.sort(extra)
	for _, k in extra do
		report("warning", path .. "." .. k, "unknown key; it is ignored")
	end
end

local function int(v: any, path: string, default: number, min: number, max: number, report: Report): number
	if v == nil then
		return default
	end
	if type(v) ~= "number" or v ~= math.floor(v) or v < min or v > max then
		report("error", path, string.format("must be an integer from %d to %d; using %d", min, max, default))
		return default
	end
	return v
end

local function str(v: any, path: string, default: string?, report: Report): string?
	if v == nil then
		return default
	end
	if type(v) ~= "string" or v == "" then
		report("error", path, "must be a non-empty string")
		return default
	end
	return v
end

function M.defaults(): Settings
	return { max_entries = 500, ci = nil }
end

local function ci(raw: any, report: Report): Ci?
	local path = "history.ci"
	if not isObject(raw) then
		report("error", path, "must be an object; CI runs stay off")
		return nil
	end
	unknown(raw, path, { "gh", "workflow", "limit", "timeout_ms", "poll_seconds" }, report)
	local workflow = str(raw.workflow, path .. ".workflow", nil, report)
	if workflow == nil then
		report("error", path .. ".workflow", "is required to list CI runs; CI runs stay off")
		return nil
	end
	return {
		gh = str(raw.gh, path .. ".gh", "gh", report) :: string,
		workflow = workflow,
		limit = int(raw.limit, path .. ".limit", 20, 1, 100, report),
		timeout_ms = int(raw.timeout_ms, path .. ".timeout_ms", 20000, 1000, 120000, report),
		poll_seconds = int(raw.poll_seconds, path .. ".poll_seconds", 300, 30, 86400, report),
	}
end

function M.parse(raw: any, report: Report): Settings
	local d = M.defaults()
	if raw == nil then
		return d
	end
	if not isObject(raw) then
		report("error", "history", "must be an object; using the defaults")
		return d
	end
	unknown(raw, "history", { "max_entries", "ci" }, report)
	return {
		max_entries = int(raw.max_entries, "history.max_entries", d.max_entries, 10, 10000, report),
		ci = if raw.ci == nil then nil else ci(raw.ci, report),
	}
end

-- The settings of a parsed config.
function M.of(config: any): Settings
	local h = if type(config) == "table" then config.history else nil
	if type(h) == "table" and type(h.max_entries) == "number" then
		return h
	end
	return M.defaults()
end

return M
