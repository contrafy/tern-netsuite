--!strict
-- SuiteQL for the script deployments view and the row model it reads.
--
-- `scriptdeployment` joined with `script`. Checked live on a sandbox
-- through a RESTlet (2026-11): `primarykey` is the deployment's internal id
-- (a number), `loglevel` is DEBUG / AUDIT / ERROR..., `recordtype` the
-- upper-case record id or null, `script` the script's internal id,
-- `scripttype` USEREVENT / SCRIPTLET / ...; the whole list (2000+ rows)
-- comes back in one RESTlet answer. Schedules (recurrence, start time) are
-- not scriptable on the deployment record, so only the status
-- (SCHEDULED / NOTSCHEDULED) says whether one is scheduled.
--
-- Activity: `scriptnote` has no deployment column, so the last 24 hours of
-- log lines and errors are counted per script (all its deployments).
-- Neither query takes user input.

local M = {}

M.MAX_ROWS = 5000
M.ACTIVITY_MAX_ROWS = 5000

M.LIST_SQL = "SELECT d.primarykey AS id, d.scriptid, d.title, d.status, d.isdeployed, d.loglevel,"
	.. " d.recordtype, d.script AS script_id, s.scriptid AS script, s.name AS script_name, s.scripttype"
	.. " FROM scriptdeployment d LEFT JOIN script s ON s.id = d.script"
	.. " ORDER BY s.scriptid, d.scriptid"

M.ACTIVITY_SQL = "SELECT n.scripttype AS script_id, COUNT(*) AS total,"
	.. " SUM(CASE WHEN n.type IN ('ERROR', 'EMERGENCY') THEN 1 ELSE 0 END) AS errors"
	.. " FROM scriptnote n WHERE n.date >= SYSDATE - 1 GROUP BY n.scripttype"

export type Deployment = {
	-- Unique in the list: `<script>:<deployment>` (see M.key). The scriptid
	-- alone is not: NetSuite names the first deployment of a script created
	-- in the UI `customdeploy1`, so it repeats across scripts (observed live).
	key: string,
	-- Internal id of the deployment record; nil when the row has none.
	id: number?,
	scriptId: string,
	title: string,
	-- Upper case, e.g. RELEASED; "" when unknown.
	status: string,
	deployed: boolean?,
	-- Upper case, e.g. DEBUG; "" when unknown.
	logLevel: string,
	recordType: string?,
	-- Internal id of the script record.
	scriptInternalId: number?,
	-- `customscript_x`, lower case.
	script: string?,
	scriptName: string?,
	-- SuiteQL script type code, e.g. USEREVENT.
	scriptType: string?,
}

export type Activity = { total: number, errors: number }

local function str(v: any): string?
	if type(v) == "string" then
		return if v ~= "" then v else nil
	elseif type(v) == "number" then
		return if v == math.floor(v) then string.format("%d", v) else tostring(v)
	end
	return nil
end

local function int(v: any): number?
	local s = str(v)
	if s == nil or not string.find(s, "^%d+$") then
		return nil
	end
	return tonumber(s)
end

local function bool(v: any): boolean?
	if v == true or v == "T" or v == "t" then
		return true
	elseif v == false or v == "F" or v == "f" then
		return false
	end
	return nil
end

-- The list key of deployment `scriptId` of script `script` (scriptids,
-- any case). SDF objects nest deployments inside their script the same way.
function M.key(script: string?, scriptId: string): string
	return string.lower(script or "") .. ":" .. string.lower(scriptId)
end

-- The deployment a SuiteQL row describes, or nil when it has no scriptid.
function M.fromRow(row: any): Deployment?
	if type(row) ~= "table" then
		return nil
	end
	local scriptId = str(row.scriptid)
	if scriptId == nil then
		return nil
	end
	local script = str(row.script)
	local scriptType = str(row.scripttype)
	return {
		key = M.key(script, scriptId),
		id = int(row.id),
		scriptId = string.lower(scriptId),
		title = str(row.title) or "",
		status = string.upper(str(row.status) or ""),
		deployed = bool(row.isdeployed),
		logLevel = string.upper(str(row.loglevel) or ""),
		recordType = str(row.recordtype),
		scriptInternalId = int(row.script_id),
		script = if script then string.lower(script) else nil,
		scriptName = str(row.script_name),
		scriptType = if scriptType then string.upper(scriptType) else nil,
	}
end

function M.fromRows(rows: { any }): { Deployment }
	local out: { Deployment } = {}
	for _, r in rows do
		local d = M.fromRow(r)
		if d then
			table.insert(out, d)
		end
	end
	return out
end

-- Activity per script internal id.
function M.activity(rows: { any }): { [number]: Activity }
	local out: { [number]: Activity } = {}
	for _, r in rows do
		if type(r) == "table" then
			local id = int(r.script_id)
			if id then
				out[id] = { total = int(r.total) or 0, errors = int(r.errors) or 0 }
			end
		end
	end
	return out
end

-- Display labels of SuiteQL script type codes; unknown codes show as is.
local TYPE_LABELS: { [string]: string } = {
	USEREVENT = "User Event",
	CLIENT = "Client",
	SCRIPTLET = "Suitelet",
	RESTLET = "RESTlet",
	SCHEDULED = "Scheduled",
	MAPREDUCE = "Map/Reduce",
	PORTLET = "Portlet",
	MASSUPDATE = "Mass Update",
	ACTION = "Workflow Action",
	BUNDLEINSTALLATION = "Bundle Install",
	SDFINSTALLATION = "SDF Install",
}

function M.typeLabel(code: string?): string
	if code == nil then
		return "?"
	end
	return TYPE_LABELS[code] or code
end

return table.freeze(M)
