--!strict
-- Reads the captured output of one SuiteCloud CLI run (validate, deploy,
-- upload, package, adddependencies) into an immutable model. Every output
-- line is either understood or kept in `unknown`, so a native view can show
-- the same content as Raw. Output with no recognizable line is "unknown"
-- and the lens shows it raw.
--
-- Two layouts reach the terminal: the Node CLI's own (local validation,
-- upload, package, dependencies) and the server log the SDK relays for
-- `--server` validation and deploys ("Validate objects -- Success",
-- "*** ERROR ***" blocks, "Create object -- id (type)").

local Argv = require("./argv")

type Invocation = Argv.Invocation

export type Family = "validate" | "deploy" | "upload" | "package" | "adddependencies"
export type Outcome = "ok" | "warnings" | "failed" | "unknown"
export type Severity = "error" | "warning"

export type Diagnostic = {
	-- Stable within one output: "d<first line number>".
	key: string,
	severity: Severity,
	message: string,
	-- Headline of a server block ("An error occurred during custom object validation.").
	title: string?,
	objectScriptId: string?,
	-- As printed: absolute for local validation, "~/..." (relative to the
	-- project folder) in server logs, "/SuiteScripts/..." for uploads.
	path: string?,
	line: number?,
	col: number?,
	-- The output lines it came from, verbatim.
	details: { string },
	source: "local" | "server" | "cli",
}

export type Group = {
	key: string,
	objectScriptId: string?,
	path: string?,
	severity: Severity,
	diagnostics: { Diagnostic },
}

export type ItemKind = "object" | "file" | "folder" | "dependency"

export type Item = {
	kind: ItemKind,
	-- "Create", "Update", "Upload", "Delete" (server log), "Uploaded",
	-- "Not uploaded", "Added".
	action: string,
	name: string,
	objectType: string?,
	error: string?,
}

export type Step = { name: string, status: string }

export type Target = {
	accountId: string?,
	accountName: string?,
	role: string?,
	-- "SANDBOX", "PRODUCTION", ... from the server log's account line.
	kind: string?,
	-- From the spinner line (`with auth ID "x"`), when the terminal kept it.
	authId: string?,
}

export type Counts = {
	errors: number,
	warnings: number,
	objects: number,
	files: number,
	dependencies: number,
	failedSteps: number,
}

export type Unknown = { line: number, text: string }

export type Result = {
	family: Family,
	command: string,
	outcome: Outcome,
	status: number?,
	-- The run talked to an account (server validation, deploy, upload).
	server: boolean,
	-- `project:deploy --dryrun`: the items are what a deploy would change.
	preview: boolean,
	target: Target?,
	project: string?,
	diagnostics: { Diagnostic },
	groups: { Group },
	items: { Item },
	steps: { Step },
	counts: Counts,
	duration: string?,
	seconds: number?,
	logFile: string?,
	packageFile: string?,
	-- The CLI's closing sentence.
	summary: string?,
	notes: { string },
	unknown: { Unknown },
	lines: { string },
}

local M = {}

local FAMILY: { [string]: Family } = {
	["project:validate"] = "validate",
	["project:deploy"] = "deploy",
	["file:upload"] = "upload",
	["project:package"] = "package",
	["project:adddependencies"] = "adddependencies",
}

function M.familyOf(command: string): Family?
	return FAMILY[command]
end

-- What Tern hands a lens is already rendered; this also cleans text that
-- still carries a spinner's carriage returns or escape sequences.
function M.clean(line: string): string
	local last = 0
	local pos = 1
	while true do
		local s, e = string.find(line, "\r", pos, true)
		local s2, e2 = string.find(line, "\27%[1?G", pos)
		if s2 and (s == nil or s2 < s) then
			s, e = s2, e2
		end
		if s == nil or e == nil then
			break
		end
		if e < #line then
			last = e
		end
		pos = e + 1
	end
	local text = if last > 0 then string.sub(line, last + 1) else line
	text = string.gsub(text, "\27%[[%d;?]*%a", "")
	text = string.gsub(text, "\r", "")
	return (string.gsub(text, "%s+$", ""))
end

local SUMMARY: { [string]: boolean } = {
	["The validation process has finished."] = true,
	["The validation process has encountered an error."] = false,
	["The deployment process has finished successfully."] = true,
	["The deployment process has encountered an error."] = false,
	["The deployment process has been canceled."] = false,
	["The preview process has encountered an error."] = false,
	["There are no dependencies to add to the manifest.xml file."] = true,
	["The uploading process has finished."] = true,
	["The uploading process has failed."] = false,
}

-- Lines that carry no result of their own.
local NOTES: { [string]: boolean } = {
	["The project is being packaged without validation. Make sure the project is validated."] = true,
	["Validating using client-side SDF metadata."] = true,
	["No errors found."] = true,
	["Begin deployment"] = true,
	["Deployment preview"] = true,
	["Installation started"] = true,
	["Validation COMPLETE"] = true,
	["Packaging..."] = true,
	["Uploading files..."] = true,
	["Adding dependencies..."] = true,
}

-- CLI errors printed as one sentence instead of a result.
local CLI_ERRORS: { string } = {
	"^There are no valid file%(s%) to upload%.$",
	"^No account has been set up for this project%.",
	"^All folders are either restricted or have no files%.$",
	"^The deployment process has been canceled",
}

local STEP_STATUS: { [string]: boolean } = { Success = true, Failed = true, Skipped = true, skipped = true }

type Mutable = {
	result: Result,
	recognized: number,
	summaryOk: boolean?,
	-- Local validation section and file.
	localSeverity: Severity?,
	localFile: string?,
	-- Server log block ("*** ERROR ***" or "WARNING --").
	block: "error" | "warning" | nil,
	stage: string?,
	current: Diagnostic?,
	-- Lines after an upload/dependency heading.
	list: "uploaded" | "notUploaded" | "dependencies" | nil,
}

local function newResult(inv: Invocation, family: Family, lines: { string }, status: number?): Result
	local log = inv.flags.log
	return {
		family = family,
		command = inv.command,
		outcome = "unknown",
		status = status,
		server = family == "deploy" or family == "upload" or (family == "validate" and inv.flags.server == true),
		preview = family == "deploy" and inv.flags.dryrun == true,
		target = nil,
		project = inv.project,
		diagnostics = {},
		groups = {},
		items = {},
		steps = {},
		counts = { errors = 0, warnings = 0, objects = 0, files = 0, dependencies = 0, failedSteps = 0 },
		duration = nil,
		seconds = nil,
		logFile = if type(log) == "string" then log else nil,
		packageFile = nil,
		summary = nil,
		notes = {},
		unknown = {},
		lines = lines,
	}
end

local function target(st: Mutable): Target
	local t = st.result.target
	if t == nil then
		local created: Target = {}
		st.result.target = created
		return created
	end
	return t
end

local function objectFromPath(path: string): string?
	return string.match(path, "[/~]Objects/.-([%w_%.%-]+)%.xml$")
end

local function addDiagnostic(st: Mutable, d: Diagnostic): Diagnostic
	table.insert(st.result.diagnostics, d)
	return d
end

local function newDiagnostic(
	n: number,
	severity: Severity,
	source: "local" | "server" | "cli",
	text: string
): Diagnostic
	return {
		key = "d" .. n,
		severity = severity,
		message = "",
		title = nil,
		objectScriptId = nil,
		path = nil,
		line = nil,
		col = nil,
		details = { text },
		source = source,
	}
end

local function endBlock(st: Mutable)
	st.block = nil
	st.stage = nil
	st.current = nil
end

local function blockDiagnostic(st: Mutable, n: number, text: string): Diagnostic
	local cur = st.current
	if cur then
		table.insert(cur.details, text)
		return cur
	end
	local d = addDiagnostic(st, newDiagnostic(n, if st.block == "warning" then "warning" else "error", "server", text))
	if st.stage then
		table.insert(d.details, 1, st.stage)
		d.title = st.stage
	end
	st.current = d
	return d
end

-- A line inside a server "*** ERROR ***" / "WARNING --" block.
local function blockLine(st: Mutable, n: number, text: string): boolean
	if text == "" then
		return true
	end
	local details = string.match(text, "^Details: (.*)$")
	if details then
		local d = blockDiagnostic(st, n, text)
		d.message = if d.message == "" then details else d.message .. "\n" .. details
		return true
	end
	local file = string.match(text, "^File: (.+)$")
	if file then
		blockDiagnostic(st, n, text).path = file
		return true
	end
	local object = string.match(text, "^Object: (%S+)")
	if object then
		blockDiagnostic(st, n, text).objectScriptId = object
		return true
	end
	if st.block ~= "error" then
		return false
	end
	local title, sid = string.match(text, "^(.-)%s*%(([%w_%.%-]+)%)$")
	if title and sid and string.find(title, "%s") then
		local d = addDiagnostic(st, newDiagnostic(n, "error", "server", text))
		if st.stage then
			table.insert(d.details, 1, st.stage)
		end
		d.title = title
		d.objectScriptId = sid
		st.current = d
		return true
	end
	if st.stage == nil and st.current == nil then
		st.stage = text
		return true
	end
	local d = addDiagnostic(st, newDiagnostic(n, "error", "server", text))
	if st.stage then
		table.insert(d.details, 1, st.stage)
	end
	d.title = text
	st.current = d
	return true
end

local function parseTarget(st: Mutable, text: string): boolean
	for _, lead in { "Validating against ", "Deploying to ", "Deployment preview for " } do
		if string.sub(text, 1, #lead) == lead then
			local rest = string.gsub(string.sub(text, #lead + 1), "%.$", "")
			local account, name, role = string.match(rest, "^(%S+) %- (.+) %- (.-)$")
			if account then
				local t = target(st)
				t.accountId = account
				t.accountName = name
				t.role = role
				if lead == "Deployment preview for " then
					st.result.preview = true
				end
				return true
			end
		end
	end
	local kind, name = string.match(text, "^Info %-%- Account %[%((%u[%u ]*)%) (.*)%]$")
	if kind then
		local t = target(st)
		t.kind = kind
		t.accountName = t.accountName or name
		return true
	end
	local auth = string.match(text, ' with auth ID "([^"]+)"')
	if auth and string.find(text, "^%a+ing project ") then
		target(st).authId = auth
		return true
	end
	return false
end

local function parseServerLog(st: Mutable, n: number, text: string): boolean
	local body = string.match(text, "^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d %(%a+%) (.*)$") or text
	local minutes, seconds = string.match(body, "^Installation COMPLETE %((%d+) minutes? (%d+) seconds?%)$")
	if minutes and seconds then
		local total = tonumber(minutes) :: number * 60 + tonumber(seconds) :: number
		st.result.seconds = total
		st.result.duration = if total >= 60
			then string.format("%dm %ds", total // 60, total % 60)
			else string.format("%ds", total)
		return true
	end
	if string.match(body, "^Installation %u+") or NOTES[body] or string.match(body, "^Begin deployment") then
		return true
	end
	local info, value = string.match(body, "^Info %-%- (.-) %[(.*)%]$")
	if info and value then
		if string.match(info, "Project$") or info == "SuiteApp" then
			st.result.project = st.result.project or value
		end
		return true
	end
	local action, kind, rest = string.match(body, "^(%a+) (%a+) %-%- (.+)$")
	if action and kind and rest and (kind == "object" or kind == "file" or kind == "folder") then
		local item: Item = { kind = kind :: ItemKind, action = action, name = rest, objectType = nil, error = nil }
		local name, objectType = string.match(rest, "^(%S+) %((.-)%)$")
		if kind == "object" and name then
			item.name = name
			item.objectType = objectType
		end
		table.insert(st.result.items, item)
		return true
	end
	local warning = string.match(body, "^WARNING %-%- (.*)$")
	if warning then
		endBlock(st)
		st.block = "warning"
		local d = addDiagnostic(st, newDiagnostic(n, "warning", "server", text))
		local title, sid = string.match(warning, "^(.-)%s*%(([%w_%.%-]+)%)$")
		d.title = title or warning
		d.objectScriptId = sid
		st.current = d
		return true
	end
	if body == "*** ERROR ***" then
		endBlock(st)
		st.block = "error"
		return true
	end
	local step, status = string.match(body, "^(.-) %-%- (%a+)$")
	if step and status and STEP_STATUS[status] then
		table.insert(st.result.steps, { name = step, status = status })
		return true
	end
	return false
end

local function parseLocal(st: Mutable, n: number, text: string): boolean
	local which = string.match(text, "^The following (%a+) were found during local validation:?$")
	if which then
		st.localSeverity = if which == "warnings" then "warning" else "error"
		st.localFile = nil
		return true
	end
	local sev, file = string.match(text, "^(%a+) for file:? (.-)%.?$")
	if (sev == "Warnings" or sev == "Errors") and file then
		st.localSeverity = if sev == "Warnings" then "warning" else "error"
		st.localFile = file
		return true
	end
	local lineNo, message = string.match(text, "^%s*%- Line No%. (%d+) %- (.*)$")
	if lineNo and message and st.localSeverity then
		local d = newDiagnostic(n, st.localSeverity :: Severity, "local", text)
		d.message = string.gsub(message, "^Error message: ", "") :: string
		d.line = tonumber(lineNo)
		d.path = st.localFile
		addDiagnostic(st, d)
		return true
	end
	-- The success layout prints the file indented on its own line.
	local path = string.match(text, "^    (%S.*)$")
	if path and st.localSeverity and not string.find(path, "^%- ") then
		st.localFile = path
		return true
	end
	return false
end

local function parseLists(st: Mutable, n: number, text: string): boolean
	if text == "The following files were uploaded:" then
		st.list = "uploaded"
		return true
	elseif text == "The following files were not uploaded:" then
		st.list = "notUploaded"
		return true
	elseif
		text == "The following dependencies were added to the manifest:"
		or text == "The following dependencies have been added to the manifest file:"
	then
		st.list = "dependencies"
		return true
	end
	local list = st.list
	if list == "uploaded" and string.sub(text, 1, 1) == "/" then
		table.insert(st.result.items, { kind = "file", action = "Uploaded", name = text })
		return true
	elseif list == "notUploaded" and string.sub(text, 1, 1) == "/" then
		local path, err = string.match(text, "^(/.-): (.*)$")
		local name = path or text
		table.insert(st.result.items, { kind = "file", action = "Not uploaded", name = name, error = err })
		local d = newDiagnostic(n, "error", "cli", text)
		d.message = err or "not uploaded"
		d.path = name
		addDiagnostic(st, d)
		return true
	elseif list == "dependencies" and text ~= "" then
		table.insert(st.result.items, { kind = "dependency", action = "Added", name = text })
		return true
	end
	return false
end

local function parseCli(st: Mutable, n: number, text: string): boolean
	local ok = SUMMARY[text]
	if ok ~= nil then
		st.result.summary = text
		st.summaryOk = if st.summaryOk == false then false else ok
		return true
	end
	if NOTES[text] then
		table.insert(st.result.notes, text)
		return true
	end
	local packageFile = string.match(text, "^The (.+) file has been successfully created%.$")
	if packageFile then
		st.result.packageFile = packageFile
		st.result.summary = text
		st.summaryOk = if st.summaryOk == false then false else true
		return true
	end
	if string.match(text, '^The ".-" project has been ') then
		table.insert(st.result.notes, text)
		return true
	end
	for _, pattern in CLI_ERRORS do
		if string.find(text, pattern) then
			local d = newDiagnostic(n, "error", "cli", text)
			d.message = text
			addDiagnostic(st, d)
			return true
		end
	end
	return false
end

-- Lines that start a new part of a server log and so end any open block.
local function structural(text: string): boolean
	local body = string.match(text, "^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d %(%a+%) (.*)$") or text
	if SUMMARY[body] ~= nil or NOTES[body] or body == "*** ERROR ***" then
		return true
	end
	if
		string.match(body, "^WARNING %-%- ")
		or string.match(body, "^Installation %u+")
		or string.match(body, "^Begin deployment")
		or string.match(body, "^%a+ %a+ %-%- ")
	then
		return true
	end
	local status = string.match(body, "^.- %-%- (%a+)$")
	return status ~= nil and STEP_STATUS[status] == true
end

local function line(st: Mutable, n: number, text: string)
	if st.block then
		if not structural(text) and blockLine(st, n, text) then
			st.recognized += 1
			return
		end
		endBlock(st)
	end
	if text == "" then
		return
	end
	if parseCli(st, n, text) or parseTarget(st, text) then
		st.list = nil
		st.recognized += 1
		return
	end
	if parseLists(st, n, text) or parseLocal(st, n, text) or parseServerLog(st, n, text) then
		st.recognized += 1
		return
	end
	table.insert(st.result.unknown, { line = n, text = text })
end

local function groupsOf(diags: { Diagnostic }): { Group }
	local groups: { Group } = {}
	local byKey: { [string]: Group } = {}
	for _, d in diags do
		local key = d.objectScriptId or d.path or ""
		local g = byKey[key]
		if g == nil then
			local created: Group = {
				key = if key == "" then "project" else key,
				objectScriptId = d.objectScriptId,
				path = d.path,
				severity = d.severity,
				diagnostics = {},
			}
			g = created
			byKey[key] = created
			table.insert(groups, created)
		end
		local group = g :: Group
		group.path = group.path or d.path
		if d.severity == "error" then
			group.severity = "error"
		end
		table.insert(group.diagnostics, d)
	end
	return groups
end

local function freezeDeep<T>(t: T): T
	for _, v in t :: any do
		if type(v) == "table" and not table.isfrozen(v) then
			freezeDeep(v)
		end
	end
	return table.freeze(t :: any) :: any
end

-- The model of one run; nil for commands this lens does not render.
function M.parse(inv: Invocation, rawLines: { string }, status: number?): Result?
	local family = FAMILY[inv.command]
	if family == nil then
		return nil
	end
	local lines: { string } = table.create(#rawLines)
	for i, l in rawLines do
		lines[i] = M.clean(l)
	end
	local st: Mutable = {
		result = newResult(inv, family :: Family, lines, status),
		recognized = 0,
		summaryOk = nil,
		localSeverity = nil,
		localFile = nil,
		block = nil,
		stage = nil,
		current = nil,
		list = nil,
	}
	for n, text in lines do
		line(st, n, text)
	end
	local r = st.result
	local counts = r.counts
	for _, d in r.diagnostics do
		if d.message == "" then
			d.message = d.title or d.details[#d.details]
		end
		-- Server blocks name the file after the headline.
		if d.objectScriptId == nil and d.path then
			d.objectScriptId = objectFromPath(d.path)
		end
		if d.severity == "error" then
			counts.errors += 1
		else
			counts.warnings += 1
		end
	end
	for _, item in r.items do
		if item.kind == "object" then
			counts.objects += 1
		elseif item.kind == "file" or item.kind == "folder" then
			counts.files += 1
		else
			counts.dependencies += 1
		end
	end
	for _, s in r.steps do
		if s.status == "Failed" then
			counts.failedSteps += 1
		end
	end
	r.groups = groupsOf(r.diagnostics)
	if st.recognized == 0 then
		r.outcome = "unknown"
	elseif (status ~= nil and status ~= 0) or st.summaryOk == false or counts.errors > 0 or counts.failedSteps > 0 then
		r.outcome = "failed"
	elseif counts.warnings > 0 then
		r.outcome = "warnings"
	else
		r.outcome = "ok"
	end
	return freezeDeep(r)
end

-- Text for the clipboard: every diagnostic of `severity` (all when nil), as
-- the CLI printed it.
function M.copyText(r: Result, severity: Severity?): string
	local parts: { string } = {}
	for _, d in r.diagnostics do
		if severity == nil or d.severity == severity then
			table.insert(parts, table.concat(d.details, "\n"))
		end
	end
	return table.concat(parts, "\n\n")
end

return table.freeze(M)
