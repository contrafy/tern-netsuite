--!strict
-- CI deploy runs from `gh run list --json` (read only), and their state for
-- the history and the status line.

local Settings = require("./settings")

export type Run = {
	id: number,
	title: string,
	branch: string?,
	sha: string?,
	-- queued, in_progress, completed, waiting, requested, pending.
	status: string,
	-- Set once completed: success, failure, cancelled, skipped, timed_out, …
	conclusion: string?,
	created: number?,
	updated: number?,
	event: string?,
	-- Only https://github.com/ links are kept.
	url: string?,
}

export type State = "running" | "ok" | "failed" | "cancelled" | "skipped"

local M = {}

M.FIELDS = "databaseId,displayTitle,headBranch,headSha,status,conclusion,createdAt,updatedAt,event,url"

function M.argv(ci: Settings.Ci, repo: string): { string }
	return {
		ci.gh,
		"run",
		"list",
		"-R",
		repo,
		"--workflow",
		ci.workflow,
		"--json",
		M.FIELDS,
		"--limit",
		tostring(ci.limit),
	}
end

local function quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- Shell command line showing a run's failed steps' logs.
function M.logCommand(gh: string, repo: string, id: number): string
	return string.format("%s run view %d -R %s --log-failed", quote(gh), id, quote(repo))
end

-- Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
local function days(y: number, m: number, d: number): number
	if m <= 2 then
		y -= 1
	end
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

-- Unix seconds of a UTC `YYYY-MM-DDTHH:MM:SSZ` timestamp.
function M.iso(s: any): number?
	if type(s) ~= "string" then
		return nil
	end
	local y, mo, d, h, mi, se = string.match(s, "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
	if y == nil then
		return nil
	end
	return days(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number) * 86400
		+ (tonumber(h) :: number) * 3600
		+ (tonumber(mi) :: number) * 60
		+ tonumber(se) :: number
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function run(doc: any): Run?
	if type(doc) ~= "table" or type(doc.databaseId) ~= "number" or type(doc.status) ~= "string" then
		return nil
	end
	local url = str(doc.url)
	if url and not string.match(url, "^https://github%.com/[^%s]+$") then
		url = nil
	end
	return {
		id = doc.databaseId,
		title = str(doc.displayTitle) or "",
		branch = str(doc.headBranch),
		sha = str(doc.headSha),
		status = doc.status,
		conclusion = str(doc.conclusion),
		created = M.iso(doc.createdAt),
		updated = M.iso(doc.updatedAt),
		event = str(doc.event),
		url = url,
	}
end

function M.parse(stdout: string, decode: (string) -> any): ({ Run }?, string?)
	local ok, doc = pcall(decode, stdout)
	if not ok or type(doc) ~= "table" then
		return nil, "gh printed something that is not a JSON run list"
	end
	local out: { Run } = {}
	for _, item in doc do
		local r = run(item)
		if r then
			table.insert(out, r)
		end
	end
	return out, nil
end

function M.errorText(status: number, stderr: string, timedOut: boolean): string
	if timedOut then
		return "gh timed out"
	end
	for line in string.gmatch(stderr, "[^\n]+") do
		local l = string.match(line, "^%s*(.-)%s*$")
		if l and l ~= "" then
			return l
		end
	end
	return "gh exited with " .. status
end

function M.state(r: Run): State
	if r.status ~= "completed" then
		return "running"
	end
	local c = r.conclusion
	if c == "success" then
		return "ok"
	elseif c == "cancelled" then
		return "cancelled"
	elseif c == "skipped" or c == "neutral" then
		return "skipped"
	end
	-- failure, timed_out, startup_failure, action_required, stale.
	return "failed"
end

-- The newest run of `branch` (by creation time).
function M.latestCi(runs: { Run }, branch: string?): Run?
	if branch == nil then
		return nil
	end
	local best: Run? = nil
	for _, r in runs do
		if r.branch == branch then
			if best == nil or (r.created or 0) > (best.created or 0) then
				best = r
			end
		end
	end
	return best
end

local TONE: { [string]: string } = {
	running = "info",
	ok = "muted",
	failed = "error",
	cancelled = "muted",
	skipped = "muted",
}

function M.segment(r: Run?): { text: string, tone: string }?
	if r == nil then
		return nil
	end
	local s = M.state(r)
	return { text = "CI deploy: " .. s, tone = TONE[s] }
end

return M
