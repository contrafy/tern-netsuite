--!strict
-- State and view of the `scaffold` block: a form for a new SuiteScript in the
-- SDF project of the directory the block was opened for, a live preview of
-- every file the plan writes or edits, and the create step. The block owns
-- the input text (Tern sends typed keys, not values); effects ask the host to
-- find and scan the project, load templates, focus an input, write files and
-- copy the validate command.

local Checks = require("../sdf/checks")
local Diff = require("./diff")
local Kinds = require("./kinds")
local Plan = require("./plan")
local Project = require("../sdf/project")
local Snapshot = require("../sdf/snapshot")
local ui = require("../ui")

type Node = ui.Node
type Project = Project.Project
type Snapshot = Snapshot.Snapshot

export type Phase = "loading" | "edit" | "writing" | "done" | "failed"

export type Values = {
	scriptType: string,
	name: string,
	scriptIdSuffix: string,
	fileName: string,
	folder: string,
	status: string,
	logLevel: string,
	recordType: string,
	-- "" means the name.
	title: string,
}

export type Notice = { tone: "error" | "info" | "success", text: string }

export type Created = {
	scriptId: string,
	scriptPath: string,
	objectPath: string,
	-- Project-relative paths written or edited.
	paths: { string },
}

export type Verify = { found: boolean, deployed: boolean, findings: { Checks.Finding } }

export type State = {
	cwd: string,
	root: string?,
	program: string,
	phase: Phase,
	-- Scans and writes of an older generation are ignored.
	gen: number,
	project: Project?,
	deployText: string?,
	manifestText: string?,
	templates: { [string]: string },
	templatesDir: string?,
	templateProblems: { string },
	values: Values,
	-- Fields the user typed into; the others follow the name.
	touched: { [string]: boolean },
	field: string,
	notice: Notice?,
	created: Created?,
	verify: Verify?,
}

-- t: "find" (cwd), "scan" (root, gen), "templates", "focus" (id),
-- "write" (root, gen, writes, edits), "copy" (text), "exit".
export type Effect = {
	t: string,
	cwd: string?,
	root: string?,
	gen: number?,
	id: string?,
	writes: { Plan.Write }?,
	edits: { Plan.Edit }?,
	text: string?,
}

export type Key = { name: string, text: string?, ctrl: boolean?, alt: boolean?, shift: boolean?, meta: boolean? }

-- t: "found" (root?), "scanned" (gen, snapshot? | err?), "templates" (dir?,
-- texts, problems), "key" (key), "action" (act, value?), "written" (gen,
-- written, err?).
export type Msg = {
	t: string,
	root: string?,
	gen: number?,
	snapshot: Snapshot?,
	err: string?,
	dir: string?,
	texts: { [string]: string }?,
	problems: { string }?,
	key: Key?,
	act: string?,
	value: string?,
	written: { string }?,
}

type Field = { id: string, label: string, choice: boolean }

local M = {}

M.INPUT_PREFIX = "main."

local FIELDS: { Field } = {
	{ id = "scriptType", label = "Type", choice = true },
	{ id = "name", label = "Name", choice = false },
	{ id = "scriptIdSuffix", label = "Script ID", choice = false },
	{ id = "fileName", label = "File", choice = false },
	{ id = "folder", label = "Folder", choice = false },
	{ id = "recordType", label = "Record type", choice = false },
	{ id = "title", label = "Title", choice = false },
	{ id = "status", label = "Status", choice = true },
	{ id = "logLevel", label = "Log level", choice = true },
}

local LABEL_WIDTH = 12

local function with(s: State, changes: { [string]: any }): State
	local n = table.clone(s) :: any
	for k, v in changes do
		n[k] = v
	end
	return n
end

local function kindOf(s: State): Kinds.Kind
	return Kinds.get(s.values.scriptType) or (Kinds.get("userevent") :: Kinds.Kind)
end

local function visible(s: State): { Field }
	local kind = kindOf(s)
	local out: { Field } = {}
	for _, f in FIELDS do
		if (f.id ~= "recordType" or kind.recordType) and (f.id ~= "title" or kind.title) then
			table.insert(out, f)
		end
	end
	return out
end

local function fieldDef(id: string): Field?
	for _, f in FIELDS do
		if f.id == id then
			return f
		end
	end
	return nil
end

local function focusEffect(id: string, effects: { Effect })
	local f = fieldDef(id)
	if f and not f.choice then
		table.insert(effects, { t = "focus", id = M.INPUT_PREFIX .. id })
	end
end

function M.init(opts: { cwd: string, program: string? }): (State, { Effect })
	local kind = Kinds.get("userevent") :: Kinds.Kind
	local s: State = {
		cwd = opts.cwd,
		root = nil,
		program = opts.program or "suitecloud",
		phase = "loading",
		gen = 0,
		project = nil,
		deployText = nil,
		manifestText = nil,
		templates = {},
		templatesDir = nil,
		templateProblems = {},
		values = {
			scriptType = kind.id,
			name = "",
			scriptIdSuffix = "",
			fileName = "",
			folder = Plan.ROOT_FOLDER,
			status = kind.statuses[1],
			logLevel = Kinds.LOG_LEVELS[1],
			recordType = "",
			title = "",
		},
		touched = {},
		field = "name",
		notice = nil,
		created = nil,
		verify = nil,
	}
	return s, { { t = "find", cwd = opts.cwd }, { t = "templates" }, { t = "focus", id = M.INPUT_PREFIX .. "name" } }
end

function M.form(s: State): Plan.Form
	local v = s.values
	return {
		scriptType = v.scriptType,
		name = v.name,
		scriptIdSuffix = v.scriptIdSuffix,
		fileName = v.fileName,
		folder = v.folder,
		deploy = {
			status = v.status,
			logLevel = v.logLevel,
			recordType = v.recordType,
			title = if v.title == "" then nil else v.title,
		},
	}
end

-- The current plan, or the problems keeping the form from one.
function M.plan(s: State): (Plan.Plan?, { Plan.Problem })
	local project = s.project
	if project == nil then
		return nil, { { field = "project", message = "the project has not been scanned yet" } }
	end
	return Plan.plan(project, M.form(s), {
		deployText = s.deployText,
		manifestText = s.manifestText,
		template = s.templates[s.values.scriptType],
	})
end

-- `cd <root> && suitecloud project:validate`, quoted for sh.
function M.validateCommand(root: string, program: string): string
	local quoted = "'" .. string.gsub(root, "'", "'\\''") .. "'"
	return string.format("cd %s && %s project:validate", quoted, program)
end

local function setValues(s: State, changes: { [string]: string }, touch: string?): State
	local v = table.clone(s.values) :: any
	local touched = s.touched
	if touch then
		touched = table.clone(touched)
		-- Clearing a field hands it back to the name.
		touched[touch] = changes[touch] ~= ""
	end
	for k, val in changes do
		v[k] = val
	end
	if changes.name ~= nil and not touched.scriptIdSuffix then
		v.scriptIdSuffix = Plan.suffixFrom(v.name)
	end
	if (changes.name ~= nil or changes.scriptIdSuffix ~= nil) and not touched.fileName then
		v.fileName = if v.scriptIdSuffix == "" then "" else v.scriptIdSuffix .. ".js"
	end
	return with(s, { values = v, touched = touched, notice = nil })
end

local function setType(s: State, id: string): State
	local kind = Kinds.get(id)
	if kind == nil or id == s.values.scriptType then
		return s
	end
	-- A status the user picked survives when the new type allows it;
	-- otherwise the new type's default applies.
	local keep = s.touched.status and table.find(kind.statuses, s.values.status) ~= nil
	local status = if keep then s.values.status else kind.statuses[1]
	return setValues(s, { scriptType = id, status = status })
end

local function cycle(list: { string }, current: string, step: number): string
	local i = table.find(list, current) or 1
	return list[(i - 1 + step) % #list + 1]
end

local function cycleField(s: State, step: number): State
	local id = s.field
	if id == "scriptType" then
		return setType(s, cycle(Kinds.ORDER, s.values.scriptType, step))
	elseif id == "status" then
		return setValues(s, { status = cycle(kindOf(s).statuses, s.values.status, step) }, "status")
	elseif id == "logLevel" then
		return setValues(s, { logLevel = cycle(Kinds.LOG_LEVELS, s.values.logLevel, step) })
	end
	return s
end

local function move(s: State, step: number, effects: { Effect }): State
	local list = visible(s)
	local index = 1
	for i, f in list do
		if f.id == s.field then
			index = i
		end
	end
	local next = list[math.clamp(index + step, 1, #list)]
	if next.id == s.field then
		return s
	end
	focusEffect(next.id, effects)
	return with(s, { field = next.id })
end

local function isLast(s: State): boolean
	local list = visible(s)
	return list[#list].id == s.field
end

local function create(s: State, effects: { Effect }): State
	if s.phase ~= "edit" or s.root == nil then
		return s
	end
	local p, problems = M.plan(s)
	if p == nil then
		local first = problems[1]
		return with(s, {
			notice = {
				tone = "error",
				text = if first then "Cannot create yet: " .. first.message else "Cannot create yet",
			},
		})
	end
	local gen = s.gen + 1
	table.insert(effects, { t = "write", root = s.root, gen = gen, writes = p.writes, edits = p.edits })
	local paths: { string } = {}
	for _, w in p.writes do
		table.insert(paths, w.path)
	end
	for _, e in p.edits do
		table.insert(paths, e.path)
	end
	return with(s, {
		phase = "writing",
		gen = gen,
		notice = { tone = "info", text = "Writing files…" },
		created = { scriptId = p.scriptId, scriptPath = p.scriptPath, objectPath = p.objectPath, paths = paths },
	})
end

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and text ~= "" and not string.find(text, "%c") then
		return text
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function typeText(s: State, text: string): State
	local id = s.field
	local current: string = (s.values :: any)[id]
	local add = string.gsub(text, "[\r\n\t]+", " ")
	if id == "scriptIdSuffix" then
		add = string.lower(add)
	end
	return setValues(s, { [id] = current .. add }, id)
end

local function backspace(s: State): State
	local id = s.field
	local current: string = (s.values :: any)[id]
	if current == "" then
		return s
	end
	local cut = utf8.offset(current, -1) or #current
	return setValues(s, { [id] = string.sub(current, 1, cut - 1) }, id)
end

local function editKey(s: State, key: Key, effects: { Effect }): State
	local name = key.name
	local f = fieldDef(s.field)
	if name == "escape" then
		table.insert(effects, { t = "exit" })
		return s
	elseif name == "enter" and (key.ctrl or key.meta) then
		return create(s, effects)
	elseif (name == "tab" and not key.shift) or name == "down" then
		return move(s, 1, effects)
	elseif (name == "tab" and key.shift) or name == "up" then
		return move(s, -1, effects)
	elseif name == "enter" then
		if isLast(s) then
			return create(s, effects)
		end
		return move(s, 1, effects)
	end
	if f == nil then
		return s
	end
	if f.choice then
		if name == "left" then
			return cycleField(s, -1)
		elseif name == "right" or name == "space" then
			return cycleField(s, 1)
		end
		return s
	end
	if name == "backspace" then
		return backspace(s)
	elseif name == "u" and key.ctrl then
		return setValues(s, { [s.field] = "" }, s.field)
	elseif name == "paste" and type(key.text) == "string" then
		return typeText(s, key.text)
	end
	local ch = printable(key)
	if ch then
		return typeText(s, ch)
	end
	return s
end

local function onKey(s: State, key: Key, effects: { Effect }): State
	if s.phase == "edit" or s.phase == "loading" then
		return editKey(s, key, effects)
	elseif s.phase == "writing" then
		return s
	end
	if key.name == "escape" or key.name == "enter" then
		table.insert(effects, { t = "exit" })
	elseif s.phase == "done" and key.name == "c" and not key.ctrl and not key.meta and s.root then
		table.insert(effects, { t = "copy", text = M.validateCommand(s.root, s.program) })
	end
	return s
end

local function onAction(s: State, act: string, value: string?, effects: { Effect }): State
	local editing = s.phase == "edit" or s.phase == "loading"
	if act == "close" then
		table.insert(effects, { t = "exit" })
	elseif act == "copy" and s.root then
		table.insert(effects, { t = "copy", text = M.validateCommand(s.root, s.program) })
	elseif not editing or (value == nil and act ~= "create") then
		return s
	elseif act == "create" then
		return create(s, effects)
	elseif act == "type" then
		return with(setType(s, value :: string), { field = "scriptType" })
	elseif act == "status" and table.find(kindOf(s).statuses, value :: string) then
		return with(setValues(s, { status = value :: string }, "status"), { field = "status" })
	elseif act == "log" and table.find(Kinds.LOG_LEVELS, value :: string) then
		return with(setValues(s, { logLevel = value :: string }), { field = "logLevel" })
	elseif act == "field" and fieldDef(value :: string) then
		if value ~= s.field then
			focusEffect(value :: string, effects)
		end
		return with(s, { field = value })
	end
	return s
end

local function textOf(snapshot: Snapshot, path: string): string?
	for _, f in snapshot.files do
		if f.path == path then
			return f.text
		end
	end
	return nil
end

local function verify(s: State, project: Project): Verify?
	local c = s.created
	if c == nil then
		return nil
	end
	local findings: { Checks.Finding } = {}
	for _, f in Checks.run({ project }) do
		if f.scriptId == c.scriptId or (f.path and table.find(c.paths, f.path)) then
			table.insert(findings, f)
		end
	end
	return {
		found = Project.object(project, c.scriptId) ~= nil,
		deployed = Project.isDeployed(project, "files", c.scriptPath)
			and Project.isDeployed(project, "objects", c.objectPath),
		findings = findings,
	}
end

local function scanned(s: State, msg: Msg): State
	if msg.gen ~= s.gen then
		return s
	end
	local snapshot = msg.snapshot
	if snapshot == nil then
		local text = "Could not scan " .. (s.root or "the project") .. ": " .. (msg.err or "unknown error")
		if s.phase == "done" then
			return with(s, { notice = { tone = "error", text = text } })
		end
		return with(s, { phase = "failed", notice = { tone = "error", text = text } })
	end
	local project = Project.build(snapshot)
	local folder = project.projectFolder
	local n = with(s, {
		project = project,
		deployText = textOf(snapshot, folder .. "/deploy.xml"),
		manifestText = textOf(snapshot, folder .. "/manifest.xml"),
	})
	if s.phase == "done" then
		local c = s.created :: Created
		return with(n, {
			verify = verify(s, project),
			notice = { tone = "success", text = string.format("Created %s (%d files).", c.scriptId, #c.paths) },
		})
	end
	return with(n, { phase = if s.phase == "loading" then "edit" else s.phase })
end

function M.update(s: State, msg: Msg): (State, { Effect })
	local effects: { Effect } = {}
	local t = msg.t
	if t == "found" then
		local root = msg.root
		if root == nil then
			return with(s, {
				phase = "failed",
				notice = {
					tone = "error",
					text = "No SuiteCloud project here: no suitecloud.config.js in " .. s.cwd .. " or above it.",
				},
			}),
				effects
		end
		local gen = s.gen + 1
		table.insert(effects, { t = "scan", root = root, gen = gen })
		return with(s, { root = root, gen = gen }), effects
	elseif t == "scanned" then
		return scanned(s, msg), effects
	elseif t == "templates" then
		return with(s, {
			templatesDir = msg.dir,
			templates = msg.texts or {},
			templateProblems = msg.problems or {},
		}),
			effects
	elseif t == "key" and msg.key then
		return onKey(s, msg.key, effects), effects
	elseif t == "action" and msg.act then
		return onAction(s, msg.act, msg.value, effects), effects
	elseif t == "written" then
		if msg.gen ~= s.gen or s.phase ~= "writing" or s.root == nil then
			return s, effects
		end
		local gen = s.gen + 1
		-- Rescan either way: a refused write usually means the files moved on.
		table.insert(effects, { t = "scan", root = s.root, gen = gen })
		if msg.err then
			return with(s, { phase = "edit", gen = gen, created = nil, notice = { tone = "error", text = msg.err } }),
				effects
		end
		return with(s, {
			phase = "done",
			gen = gen,
			notice = {
				tone = "success",
				text = "Created " .. #(msg.written or {}) .. " files; rescanning the project…",
			},
		}),
			effects
	end
	return s, effects
end

-- View -------------------------------------------------------------------------

local function pad(label: string): string
	return label .. string.rep(" ", math.max(1, LABEL_WIDTH - #label))
end

local function fieldMark(s: State, id: string): Node
	return ui.text({ ui.span(if s.field == id then "›" else " ", "accent") })
end

local function chips(s: State, id: string, options: { string }, labels: { [string]: string }?, act: string): Node
	local current: string = (s.values :: any)[id]
	local out: { Node } = {
		fieldMark(s, id),
		ui.text({ ui.span(pad((fieldDef(id) :: Field).label), if s.field == id then "strong" else "muted") }, {
			actions = { click = "field=" .. id },
		}),
	}
	for _, o in options do
		table.insert(
			out,
			ui.badge(
				if labels then labels[o] or o else o,
				if o == current then "accent" else "neutral",
				{ key = id .. "-" .. o, actions = { click = act .. "=" .. o } }
			)
		)
	end
	return ui.row(out, { key = id, wrap = true })
end

local PLACEHOLDERS: { [string]: string } = {
	name = "shown in NetSuite, at most 40 characters",
	scriptIdSuffix = "after customscript_ / customdeploy_",
	fileName = "<script id>.js",
	folder = "/SuiteScripts/...",
	recordType = "SALESORDER, CUSTOMER, or customrecord_x",
}

local function input(s: State, id: string): Node
	local text: string = (s.values :: any)[id]
	local placeholder = PLACEHOLDERS[id]
	if id == "title" then
		placeholder = if s.values.name ~= "" then s.values.name .. " (the name)" else "defaults to the name"
	end
	return {
		k = "input",
		p = {
			key = id,
			text = text,
			cursor = #text,
			prompt = (if s.field == id then "› " else "  ") .. pad((fieldDef(id) :: Field).label),
			placeholder = placeholder,
		},
	}
end

local function problemLine(id: string, message: string): Node
	return ui.text({ ui.span(string.rep(" ", LABEL_WIDTH + 2)), ui.span(message, "error") }, { key = id .. "-problem" })
end

local function header(s: State): Node
	local project = s.project
	local spans: { ui.SpanLike } = { ui.span("New SuiteScript", "strong") }
	if project then
		table.insert(spans, ui.span("  in " .. project.name .. "  ", "muted"))
		table.insert(spans, ui.span(project.root, "muted"))
	elseif s.root then
		table.insert(spans, ui.span("  scanning " .. s.root .. "…", "muted"))
	elseif s.phase == "loading" then
		table.insert(spans, ui.span("  looking for the SuiteCloud project of " .. s.cwd .. "…", "muted"))
	end
	return ui.text(spans, { key = "head" })
end

local function noticeNode(n: Notice): Node
	local tone = if n.tone == "error" then "error" elseif n.tone == "success" then "success" else "muted"
	return ui.text({ ui.span(n.text, tone) }, { key = "notice" })
end

local function preview(p: Plan.Plan): { Node }
	local out: { Node } = { ui.rule({ "Preview" }, { key = "preview-rule" }) }
	for _, w in p.writes do
		table.insert(
			out,
			ui.section({ ui.span(w.path, "strong"), ui.span("  new file", "success") }, {
				ui.code(w.content, w.lang, 1, { key = "code" }),
			}, { key = "w:" .. w.path, open = true })
		)
	end
	for _, e in p.edits do
		table.insert(
			out,
			ui.section({ ui.span(e.path, "strong"), ui.span("  edit", "warning") }, {
				ui.muted(e.reason, { key = "why" }),
				{ k = "diff", p = { key = "diff", text = Diff.unified(e.path, e.from, e.to), path = e.path } },
			}, { key = "e:" .. e.path, open = true })
		)
	end
	for i, w in p.warnings do
		table.insert(out, ui.text({ ui.span(w, "warning") }, { key = "warn" .. i }))
	end
	return out
end

local function doneNodes(s: State): { Node }
	local c = s.created :: Created
	local out: { Node } = {}
	local items: { { { ui.SpanLike } } } = {}
	for _, path in c.paths do
		table.insert(items, { { "Wrote" }, { path } })
	end
	local v = s.verify
	if v then
		local found: { ui.SpanLike } = {
			ui.span(
				if v.found then c.scriptId .. " found in the rescan" else c.scriptId .. " missing",
				if v.found then "success" else "error"
			),
		}
		local deployed: { ui.SpanLike } = {
			ui.span(
				if v.deployed then "deploys both files" else "does not deploy both files",
				if v.deployed then "success" else "error"
			),
		}
		local projectRow: { { ui.SpanLike } } = { { "Project" }, found }
		local deployRow: { { ui.SpanLike } } = { { "deploy.xml" }, deployed }
		table.insert(items, projectRow)
		table.insert(items, deployRow)
	end
	table.insert(out, ui.kv(items))
	if v then
		for i, f in v.findings do
			table.insert(
				out,
				ui.text({
					ui.span(f.severity .. "  ", if f.severity == "error" then "error" else "warning"),
					ui.span(f.message),
				}, { key = "finding" .. i })
			)
		end
	end
	if s.root then
		table.insert(out, ui.code(M.validateCommand(s.root, s.program), "sh", nil, { key = "validate" }))
	end
	return out
end

-- A region's root is not drawn, so the buttons need their own row.
local function dock(buttons: { Node }, hint: string): Node
	return ui.col({ ui.row(buttons, { key = "buttons" }), ui.muted(hint, { key = "hint" }) })
end

function M.view(s: State): { main: Node, dock: Node }
	local main: { Node } = { header(s) }
	local notice = s.notice
	if notice then
		table.insert(main, noticeNode(notice))
	end
	if s.phase == "done" then
		for _, n in doneNodes(s) do
			table.insert(main, n)
		end
		return {
			main = ui.col(main, { role = "tern-netsuite.scaffold" }),
			dock = dock({
				ui.badge("Copy validate command", "accent", { key = "copy", actions = { click = "copy" } }),
				ui.badge("Close", "neutral", { key = "close", actions = { click = "close" } }),
			}, "c copies · Esc closes"),
		}
	end
	if s.phase == "failed" then
		return {
			main = ui.col(main, { role = "tern-netsuite.scaffold" }),
			dock = dock(
				{ ui.badge("Close", "neutral", { key = "close", actions = { click = "close" } }) },
				"Esc closes"
			),
		}
	end

	local p, problems = M.plan(s)
	local byField: { [string]: string } = {}
	for _, pr in problems do
		byField[pr.field] = byField[pr.field] or pr.message
	end
	local labels: { [string]: string } = {}
	for _, id in Kinds.ORDER do
		labels[id] = (Kinds.get(id) :: Kinds.Kind).label
	end
	for _, f in visible(s) do
		if f.id == "scriptType" then
			table.insert(main, chips(s, f.id, Kinds.ORDER, labels, "type"))
		elseif f.id == "status" then
			table.insert(main, chips(s, f.id, kindOf(s).statuses, nil, "status"))
		elseif f.id == "logLevel" then
			table.insert(main, chips(s, f.id, Kinds.LOG_LEVELS, nil, "log"))
		else
			table.insert(main, input(s, f.id))
		end
		local message = byField[f.id]
		-- Empty required fields are not errors until the user gets to them.
		local blank = f.id ~= "scriptType" and (s.values :: any)[f.id] == ""
		if message and not blank then
			table.insert(main, problemLine(f.id, message))
		end
	end
	if byField.project and s.project then
		table.insert(main, ui.text({ ui.span(byField.project, "error") }, { key = "project-problem" }))
	end
	local template = s.templates[s.values.scriptType]
	if template and s.templatesDir then
		table.insert(
			main,
			ui.muted("Template: " .. s.templatesDir .. "/" .. s.values.scriptType .. ".js", {
				key = "template",
			})
		)
	end
	for i, problem in s.templateProblems do
		table.insert(main, ui.text({ ui.span(problem, "warning") }, { key = "tplproblem" .. i }))
	end
	if p then
		for _, n in preview(p) do
			table.insert(main, n)
		end
	end

	local ready = p ~= nil and s.phase == "edit"
	return {
		main = ui.col(main, { role = "tern-netsuite.scaffold" }),
		dock = dock(
			{
				ui.badge(
					if s.phase == "writing" then "Creating…" else "Create",
					if ready then "accent" else "neutral",
					{ key = "create", actions = if ready then { click = "create" } else nil }
				),
				ui.badge("Cancel", "neutral", { key = "close", actions = { click = "close" } }),
			},
			"Tab / ↑↓ fields · ←→ choose · Enter next (creates on the last field) · Ctrl+Enter creates · Esc closes"
		),
	}
end

function M.title(s: State): string
	local project = s.project
	return if project then "New SuiteScript · " .. project.name else "New SuiteScript"
end

return M
