--!strict
-- State of the `deployments` block: a connection's script deployments
-- (SuiteQL, read only), filters, NetSuite UI pages, the execution log tail
-- of a deployment's script, and edits of a deployment's log level or status
-- in the local SDF project that defines it. `update` returns the next state
-- and the effects plugin/deployments_host.luau runs; nothing here touches
-- `tern`.
--
-- The plugin never writes to NetSuite. An edit changes one element of the
-- object XML (lib/deployments/xmledit.luau) after a diff preview, and only
-- if the file still has the bytes that were previewed (the write effect
-- carries their SHA-256; WRITE_SCRIPT compares before replacing). The user
-- deploys the project afterwards, through the guard.

local Classify = require("../account/classify")
local Config = require("../config")
local Connect = require("../ns/connect")
local Crypto = require("../ns/crypto")
local Errors = require("../ns/errors")
local Filter = require("./filter")
local Link = require("./link")
local LogsLink = require("../monitor/logs/link")
local Owners = require("./owners")
local Pages = require("./pages")
local Project = require("../sdf/project")
local Query = require("./query")
local Values = require("./values")
local XmlEdit = require("./xmledit")

type NsError = Errors.NsError
type Deployment = Query.Deployment
type Field = Values.Field

local M = {}

export type Target = Connect.Target

export type Key = {
	name: string,
	text: string?,
	ctrl: boolean?,
	alt: boolean?,
	shift: boolean?,
	meta: boolean?,
}

export type Effect = {
	t: "query" | "scan" | "read" | "write" | "open" | "logs" | "copy" | "focus" | "save" | "exit",
	req: number?,
	connection: string?,
	sql: string?,
	max_rows: number?,
	cwd: string?,
	path: string?,
	text: string?,
	-- write: SHA-256 (hex) the file must still have.
	expect: string?,
	url: string?,
	id: string?,
}

export type Msg = {
	t: "key" | "action" | "result" | "scanned" | "read" | "wrote" | "resize",
	key: Key?,
	act: string?,
	value: string?,
	req: number?,
	rows: { any }?,
	truncated: boolean?,
	err: NsError?,
	-- Wall-clock time of a result, as the host formats it.
	at: string?,
	projects: { Project.Project }?,
	errors: { string }?,
	text: string?,
	-- read / wrote: why it failed.
	error: string?,
	height: number?,
	width: number?,
}

export type EditPhase = "reading" | "choose" | "preview" | "writing" | "done" | "error"

export type Edit = {
	phase: EditPhase,
	deployment: string,
	owner: Owners.Owner,
	req: number,
	field: Field,
	-- Index into the field's choices.
	index: number,
	target: XmlEdit.Target?,
	text: string?,
	hash: string?,
	plan: XmlEdit.Plan?,
	message: string?,
	-- Shown in every phase: the project deploys elsewhere, and so on.
	warning: string?,
	command: string?,
	commandWhy: string?,
}

export type ScanPhase = "idle" | "scanning" | "done"

export type State = {
	targets: { Target },
	selected: number,
	cfg: Config.Config,
	cwd: string?,
	rows: { Deployment },
	truncated: boolean,
	loaded: boolean,
	inflight: number?,
	err: NsError?,
	loadedAt: string?,
	activity: { [number]: Query.Activity }?,
	activityReq: number?,
	activityErr: NsError?,
	seq: number,
	filter: Filter.Filter,
	editing: boolean,
	-- Opened from a plain link: nothing is queried until Enter.
	held: boolean,
	selId: string?,
	offset: number,
	detailOpen: boolean,
	height: number?,
	width: number?,
	scan: ScanPhase,
	owners: Owners.Index,
	scanErrors: { string },
	edit: Edit?,
	notice: string?,
}

M.FILTER_INPUT = "main.filter"
M.SAVE_VERSION = 1
M.MAX_RENDER_ROWS = 200
M.SCROLLOFF = 2
M.CHROME_LINES = 7
M.DOCK_LINES = 10
M.MIN_VIEWPORT = 12
-- Object files larger than this are not edited (and a read of that size is
-- treated as truncated).
M.MAX_FILE_BYTES = 4 * 1024 * 1024

-- argv tail: "$1" file, "$2" expected SHA-256; the new content on stdin.
-- Exit 3: the file changed since it was read; 4: no SHA-256 tool; 7: the
-- path is a symlink. The mode of the file is kept.
M.WRITE_SCRIPT = [[
f=$1
want=$2
[ -L "$f" ] && { echo 'the file is a symlink' >&2; exit 7; }
[ -f "$f" ] || { echo 'the file is gone' >&2; exit 3; }
if command -v shasum >/dev/null 2>&1; then have=$(shasum -a 256 <"$f") || exit 5
elif command -v sha256sum >/dev/null 2>&1; then have=$(sha256sum <"$f") || exit 5
else echo 'neither shasum nor sha256sum is available' >&2; exit 4
fi
have=${have%% *}
[ "$have" = "$want" ] || { echo 'the file changed since it was read' >&2; exit 3; }
mode=$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f") || exit 5
tmp="$f.tern-netsuite.tmp"
if cat >"$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$f"; then exit 0; fi
rm -f "$tmp"
exit 6
]]

-- What a WRITE_SCRIPT exit status means, nil for success.
function M.writeError(status: number, stderr: string): string?
	if status == 0 then
		return nil
	elseif status == 3 then
		return "The file changed since it was read; nothing was written. Edit again to see the current file."
	elseif status == 7 then
		return "The file is a symlink; nothing was written."
	end
	local detail = string.match(stderr, "^%s*([^\n]+)")
	return "The file could not be written" .. (if detail then ": " .. detail else string.format(" (exit %d)", status))
end

-- Accessors ---------------------------------------------------------------------

function M.target(s: State): Target?
	return s.targets[s.selected]
end

function M.visible(s: State): { Deployment }
	if Filter.isEmpty(s.filter) then
		return s.rows
	end
	local out: { Deployment } = {}
	for _, d in s.rows do
		if Filter.matches(d, s.filter) then
			table.insert(out, d)
		end
	end
	return out
end

local function indexOf(list: { Deployment }, id: string?): number
	if id == nil then
		return 1
	end
	for i, d in list do
		if d.scriptId == id then
			return i
		end
	end
	return 1
end

function M.selectedIndex(s: State, list: { Deployment }?): number
	return indexOf(list or M.visible(s), s.selId)
end

function M.selected(s: State): Deployment?
	local list = M.visible(s)
	return list[indexOf(list, s.selId)]
end

-- The local project an edit of `d` applies to, or nil and why.
function M.owner(s: State, d: Deployment): (Owners.Owner?, string?)
	if s.scan ~= "done" then
		return nil, "local SDF projects are still being scanned"
	end
	return Owners.pick(s.owners, d.scriptId, s.cwd)
end

function M.activityOf(s: State, d: Deployment): Query.Activity?
	local a = s.activity
	if a == nil or d.scriptInternalId == nil then
		return nil
	end
	return a[d.scriptInternalId :: number] or { total = 0, errors = 0 }
end

function M.deploymentPage(s: State, d: Deployment): string?
	local tg = M.target(s)
	return if tg then Pages.deployment(tg.account_id, d.id) else nil
end

function M.scriptPage(s: State, d: Deployment): string?
	local tg = M.target(s)
	return if tg then Pages.script(tg.account_id, d.scriptInternalId) else nil
end

-- The values the edit's field may take.
function M.choices(e: Edit): { string }
	local tg = e.target
	if tg == nil then
		return {}
	end
	return Values.allowed(tg.tag, e.field, tg.recurrence) or {}
end

function M.viewport(height: number?, detailOpen: boolean): number
	local h = (height or 40) - M.CHROME_LINES - (if detailOpen then M.DOCK_LINES else 0)
	return math.max(h, M.MIN_VIEWPORT)
end

-- Rows `[first, last]` of a `size`-row window over `total` rows keeping
-- `selected` SCROLLOFF rows from either edge, moving `offset` minimally.
function M.window(selected: number, total: number, offset: number, size: number): (number, number)
	if total <= size then
		return 1, total
	end
	local so = math.min(M.SCROLLOFF, (size - 1) // 2)
	local sel = math.clamp(selected, 1, total)
	local first = offset
	if sel < first + so then
		first = sel - so
	elseif sel > first + size - 1 - so then
		first = sel - size + 1 + so
	end
	first = math.clamp(first, 1, total - size + 1)
	return first, first + size - 1
end

-- Loading -----------------------------------------------------------------------

local function startList(s: State, effects: { Effect })
	local tg = M.target(s)
	if tg == nil then
		return
	end
	s.seq += 1
	s.inflight = s.seq
	s.activityReq = nil
	table.insert(effects, {
		t = "query",
		req = s.seq,
		connection = tg.id,
		sql = Query.LIST_SQL,
		max_rows = Query.MAX_ROWS,
	})
end

local function startActivity(s: State, effects: { Effect })
	local tg = M.target(s)
	if tg == nil then
		return
	end
	s.seq += 1
	s.activityReq = s.seq
	table.insert(effects, {
		t = "query",
		req = s.seq,
		connection = tg.id,
		sql = Query.ACTIVITY_SQL,
		max_rows = Query.ACTIVITY_MAX_ROWS,
	})
end

local function reload(s: State, effects: { Effect })
	s.err = nil
	s.activity = nil
	s.activityErr = nil
	s.notice = nil
	startList(s, effects)
end

local function onResult(s: State, msg: Msg, effects: { Effect }): boolean
	if msg.req ~= nil and msg.req == s.inflight then
		s.inflight = nil
		s.loadedAt = msg.at
		if msg.err then
			s.err = msg.err
			return true
		end
		s.err = nil
		s.rows = Query.fromRows(msg.rows or {})
		s.truncated = msg.truncated == true
		s.loaded = true
		startActivity(s, effects)
		return true
	elseif msg.req ~= nil and msg.req == s.activityReq then
		s.activityReq = nil
		if msg.err then
			s.activityErr = msg.err
		else
			s.activityErr = nil
			s.activity = Query.activity(msg.rows or {})
		end
		return true
	end
	return false
end

local function onScanned(s: State, msg: Msg): boolean
	s.scan = "done"
	s.owners = Owners.index(msg.projects or {})
	s.scanErrors = msg.errors or {}
	return true
end

-- Editing -----------------------------------------------------------------------

local function account(s: State, owner: Owners.Owner): string?
	local tg = M.target(s)
	if tg == nil then
		return nil
	end
	local authId = owner.authId
	if authId == nil then
		return string.format(
			"%s has no defaultAuthId in project.json: check where it deploys before running the deploy.",
			owner.name
		)
	end
	local r = Classify.authId(authId, s.cfg)
	if r == nil then
		return string.format(
			"Auth ID %s of %s is not in the config: make sure it deploys to %s.",
			authId,
			owner.name,
			tg.account_label
		)
	elseif r.accountId ~= tg.account_id then
		return string.format(
			"%s deploys to %s (auth ID %s), not to %s, the account this view shows.",
			owner.name,
			r.label,
			authId,
			tg.account_label
		)
	end
	return nil
end

local function beginEdit(s: State, d: Deployment, effects: { Effect }): boolean
	local owner, why = M.owner(s, d)
	if owner == nil then
		s.notice = why
		return true
	end
	s.notice = nil
	s.seq += 1
	s.edit = {
		phase = "reading",
		deployment = d.scriptId,
		owner = owner,
		req = s.seq,
		field = "loglevel",
		index = 1,
		target = nil,
		text = nil,
		hash = nil,
		plan = nil,
		message = nil,
		warning = account(s, owner),
		command = nil,
		commandWhy = nil,
	}
	table.insert(effects, { t = "read", req = s.seq, path = owner.path })
	return true
end

local function fail(e: Edit, message: string)
	e.phase = "error"
	e.message = message
	e.plan = nil
end

-- Puts the choice cursor on the field's current value.
local function focusCurrent(e: Edit)
	local choices = M.choices(e)
	local current = if e.target then e.target.values[e.field] else nil
	e.index = (if current then table.find(choices, current) else nil) or 1
end

local function onRead(s: State, msg: Msg): boolean
	local e = s.edit
	if e == nil or msg.req ~= e.req or e.phase ~= "reading" then
		return false
	end
	local text = msg.text
	if text == nil then
		fail(e, "Could not read " .. e.owner.rel .. ": " .. (msg.error or "unknown error"))
		return true
	end
	if #text >= M.MAX_FILE_BYTES then
		fail(e, e.owner.rel .. " is too large to edit here.")
		return true
	end
	local target, why = XmlEdit.locate(text, e.deployment)
	if target == nil then
		fail(e, e.owner.rel .. ": " .. (why or "the deployment could not be located"))
		return true
	end
	e.text = text
	e.hash = Crypto.hex(Crypto.sha256(text))
	e.target = target
	e.phase = "choose"
	e.message = nil
	focusCurrent(e)
	return true
end

local function setField(e: Edit, field: Field)
	if e.field ~= field then
		e.field = field
		e.message = nil
		focusCurrent(e)
	end
end

local function preview(e: Edit)
	local value = M.choices(e)[e.index]
	if value == nil or e.target == nil or e.text == nil then
		return
	end
	local plan, why = XmlEdit.plan(e.text :: string, e.target :: XmlEdit.Target, e.field, value)
	if plan == nil then
		e.message = why
		return
	end
	e.plan = plan
	e.message = nil
	e.phase = "preview"
end

local function write(s: State, e: Edit, effects: { Effect })
	local plan = e.plan
	if plan == nil or e.hash == nil then
		return
	end
	s.seq += 1
	e.req = s.seq
	e.phase = "writing"
	table.insert(effects, {
		t = "write",
		req = s.seq,
		path = e.owner.path,
		text = plan.text,
		expect = e.hash,
	})
end

local function onWrote(s: State, msg: Msg): boolean
	local e = s.edit
	if e == nil or msg.req ~= e.req or e.phase ~= "writing" then
		return false
	end
	if msg.error then
		fail(e, msg.error :: string)
		return true
	end
	e.phase = "done"
	e.command, e.commandWhy = Owners.deployCommand(e.owner.root)
	return true
end

local function editKey(s: State, e: Edit, key: Key, effects: { Effect }): boolean
	local name = key.name
	local ch = if key.ctrl or key.meta or key.alt then nil else (key.text or name)
	if e.phase == "writing" or e.phase == "reading" then
		return false
	elseif e.phase == "choose" then
		if name == "escape" then
			s.edit = nil
		elseif name == "tab" or ch == "f" then
			setField(e, if e.field == "loglevel" then "status" else "loglevel")
		elseif name == "left" or ch == "h" then
			e.index = math.max(e.index - 1, 1)
			e.message = nil
		elseif name == "right" or ch == "l" then
			e.index = math.min(e.index + 1, math.max(#M.choices(e), 1))
			e.message = nil
		elseif name == "enter" or name == "return" then
			preview(e)
		else
			return false
		end
	elseif e.phase == "preview" then
		if name == "enter" or name == "return" or ch == "w" then
			write(s, e, effects)
		elseif name == "escape" or name == "backspace" then
			e.phase = "choose"
			e.plan = nil
		else
			return false
		end
	elseif e.phase == "done" then
		if ch == "y" and e.command then
			table.insert(effects, { t = "copy", text = e.command })
			return false
		elseif name == "escape" or name == "enter" or name == "return" then
			s.edit = nil
		else
			return false
		end
	else
		if name == "escape" or name == "enter" or name == "return" then
			s.edit = nil
		elseif ch == "r" then
			local d = M.selected(s)
			s.edit = nil
			if d and d.scriptId == e.deployment then
				return beginEdit(s, d, effects)
			end
		else
			return false
		end
	end
	return true
end

-- List commands -----------------------------------------------------------------

local function move(s: State, delta: number)
	local list = M.visible(s)
	if #list == 0 then
		return
	end
	local i = math.clamp(indexOf(list, s.selId) + delta, 1, #list)
	s.selId = list[i].scriptId
end

local function selectTarget(s: State, index: number, effects: { Effect }): boolean
	if s.targets[index] == nil or (index == s.selected and s.err == nil and s.loaded) then
		return false
	end
	s.selected = index
	s.rows = {}
	s.loaded = false
	s.selId = nil
	s.offset = 1
	s.edit = nil
	reload(s, effects)
	table.insert(effects, { t = "save" })
	return true
end

local function setText(s: State, text: string)
	s.filter = Filter.withText(s.filter, text)
end

local function cycleFacet(s: State, facet: Filter.Facet)
	local f = table.clone(s.filter);
	(f :: any)[facet] = Filter.cycle(Filter.values(s.rows, facet), (f :: any)[facet])
	s.filter = f
end

local function printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function editFilterKey(s: State, key: Key): boolean
	local name = key.name
	if name == "escape" or name == "enter" or name == "return" then
		s.editing = false
	elseif name == "backspace" then
		local t = s.filter.text
		if t == "" then
			return false
		end
		setText(s, string.sub(t, 1, (utf8.offset(t, -1) or #t) - 1))
	elseif name == "u" and key.ctrl then
		setText(s, "")
	elseif name == "down" then
		move(s, 1)
	elseif name == "up" then
		move(s, -1)
	elseif name == "paste" and type(key.text) == "string" then
		setText(s, s.filter.text .. (string.gsub(key.text, "%c", " ")))
	else
		local ch = printable(key)
		if ch == nil then
			return false
		end
		setText(s, s.filter.text .. ch)
	end
	return true
end

local function start(s: State, effects: { Effect })
	s.held = false
	startList(s, effects)
	if s.scan == "idle" then
		s.scan = "scanning"
		table.insert(effects, { t = "scan", cwd = s.cwd })
	end
	table.insert(effects, { t = "save" })
end

local function openPage(s: State, which: string, effects: { Effect }): boolean
	local d = M.selected(s)
	if d == nil then
		return false
	end
	local url = if which == "script" then M.scriptPage(s, d) else M.deploymentPage(s, d)
	if url == nil then
		s.notice = "NetSuite returned no internal id for this "
			.. (if which == "script" then "script" else "deployment")
		return true
	end
	table.insert(effects, { t = "open", url = url })
	return false
end

local function tailLogs(s: State, effects: { Effect }): boolean
	local d = M.selected(s)
	local tg = M.target(s)
	if d == nil or tg == nil then
		return false
	end
	local script = d.script or (if d.scriptInternalId then string.format("%d", d.scriptInternalId :: number) else nil)
	if script == nil or LogsLink.script(script) == nil then
		s.notice = "This deployment has no script id to tail logs for"
		return true
	end
	table.insert(effects, {
		t = "logs",
		url = LogsLink.url({ connection = tg.id, scripts = { script :: string } }),
	})
	return false
end

local function heldKey(s: State, key: Key, effects: { Effect }): boolean
	if key.ctrl or key.meta or key.alt then
		return false
	elseif key.name == "escape" then
		table.insert(effects, { t = "exit" })
		return false
	elseif key.name == "enter" or key.name == "return" then
		start(s, effects)
		return true
	end
	return false
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	if s.held then
		return heldKey(s, key, effects)
	end
	local e = s.edit
	if e then
		return editKey(s, e, key, effects)
	end
	if s.editing then
		return editFilterKey(s, key)
	end
	local name = key.name
	local ch = printable(key)
	local page = M.viewport(s.height, s.detailOpen)
	if name == "escape" then
		table.insert(effects, { t = "exit" })
		return false
	elseif ch == "j" or name == "down" then
		move(s, 1)
	elseif ch == "k" or name == "up" then
		move(s, -1)
	elseif name == "page_down" then
		move(s, page)
	elseif name == "page_up" then
		move(s, -page)
	elseif ch == "g" or name == "home" then
		s.selId = nil
	elseif ch == "G" or name == "end" then
		move(s, math.huge)
	elseif name == "enter" or name == "return" then
		s.detailOpen = not s.detailOpen
	elseif ch == "/" then
		s.editing = true
		table.insert(effects, { t = "focus", id = M.FILTER_INPUT })
	elseif ch == "t" then
		cycleFacet(s, "type")
	elseif ch == "s" then
		cycleFacet(s, "status")
	elseif ch == "l" then
		cycleFacet(s, "level")
	elseif ch == "x" then
		s.filter = Filter.new()
	elseif ch == "o" then
		return openPage(s, "deployment", effects)
	elseif ch == "O" then
		return openPage(s, "script", effects)
	elseif ch == "L" then
		return tailLogs(s, effects)
	elseif ch == "e" then
		local d = M.selected(s)
		return d ~= nil and beginEdit(s, d, effects)
	elseif ch == "c" then
		if #s.targets == 0 then
			return false
		end
		return selectTarget(s, s.selected % #s.targets + 1, effects)
	elseif ch == "r" then
		if M.target(s) == nil and #s.targets > 0 then
			s.selected = 1
		end
		reload(s, effects)
	else
		return false
	end
	return true
end

local function editAction(s: State, e: Edit, act: string, value: string, effects: { Effect }): boolean
	-- A plain string: the type checker narrows the phase union across branches.
	local phase: string = e.phase
	if act == "field" and (value == "loglevel" or value == "status") and phase == "choose" then
		setField(e, value :: Field)
	elseif act == "value" and phase == "choose" then
		local i = table.find(M.choices(e), value)
		if i == nil then
			return false
		end
		e.index = i
		preview(e)
	elseif act == "preview" and phase == "choose" then
		preview(e)
	elseif act == "write" and phase == "preview" then
		write(s, e, effects)
	elseif act == "back" and phase == "preview" then
		e.phase = "choose"
		e.plan = nil
	elseif act == "copy" and phase == "done" and e.command then
		table.insert(effects, { t = "copy", text = e.command })
		return false
	elseif act == "cancel" and phase ~= "writing" then
		s.edit = nil
	else
		return false
	end
	return true
end

local function onAction(s: State, act: string, value: string, effects: { Effect }): boolean
	if s.held then
		if act == "start" then
			start(s, effects)
			return true
		elseif act == "close" then
			table.insert(effects, { t = "exit" })
		end
		return false
	end
	local e = s.edit
	if e and editAction(s, e, act, value, effects) then
		return true
	end
	if act == "sel" then
		if s.selId == value then
			s.detailOpen = not s.detailOpen
		else
			s.selId = value
			s.detailOpen = true
		end
	elseif act == "conn" then
		for i, tg in s.targets do
			if tg.id == value then
				return selectTarget(s, i, effects)
			end
		end
		return false
	elseif act == "reload" then
		reload(s, effects)
	elseif act == "facet" and (value == "type" or value == "status" or value == "level") then
		cycleFacet(s, value :: Filter.Facet)
		table.insert(effects, { t = "save" })
	elseif act == "clear" then
		s.filter = Filter.new()
		s.editing = false
		table.insert(effects, { t = "save" })
	elseif act == "open" then
		return openPage(s, value, effects)
	elseif act == "logs" then
		return tailLogs(s, effects)
	elseif act == "edit" then
		local d = M.selected(s)
		return d ~= nil and e == nil and beginEdit(s, d, effects)
	elseif act == "connect" then
		local tg = M.target(s)
		if tg then
			table.insert(effects, { t = "open", url = LogsLink.connectUrl(tg.id) })
		end
		return false
	elseif act == "filter-focus" then
		if s.editing then
			return false
		end
		s.editing = true
		table.insert(effects, { t = "focus", id = M.FILTER_INPUT })
	elseif act == "page" then
		move(s, (if value == "up" then -1 else 1) * M.viewport(s.height, s.detailOpen))
	elseif act == "close" then
		table.insert(effects, { t = "exit" })
		return false
	else
		return false
	end
	return true
end

local function settle(s: State)
	local list = M.visible(s)
	local i = indexOf(list, s.selId)
	if s.selId ~= nil and (list[i] == nil or list[i].scriptId ~= s.selId) then
		s.selId = nil
		i = 1
	end
	if s.selId == nil and list[1] then
		s.selId = list[1].scriptId
	end
	s.offset = M.window(i, #list, s.offset, M.MAX_RENDER_ROWS)
end

-- Init / update -----------------------------------------------------------------

function M.init(args: { string }, saved: any, cfg: Config.Config, cwd: string?): (State, { Effect })
	local launch, problems = Link.fromArgs(args)
	local targets = Connect.targets(cfg)
	local s: State = {
		targets = targets,
		selected = if #targets > 0 then 1 else 0,
		cfg = cfg,
		cwd = if cwd and string.sub(cwd, 1, 1) == "/" then cwd else nil,
		rows = {},
		truncated = false,
		loaded = false,
		inflight = nil,
		err = nil,
		loadedAt = nil,
		activity = nil,
		activityReq = nil,
		activityErr = nil,
		seq = 0,
		filter = Filter.withText(Filter.new(), launch.query or ""),
		editing = false,
		held = launch.hold == true,
		selId = nil,
		offset = 1,
		detailOpen = true,
		height = nil,
		width = nil,
		scan = "idle",
		owners = {},
		scanErrors = {},
		edit = nil,
		notice = if #problems > 0 then "Ignored launch arguments: " .. table.concat(problems, "; ") else nil,
	}
	local wanted = launch.connection
	if type(saved) == "table" and saved.v == M.SAVE_VERSION then
		local f = s.filter
		if launch.query == nil and type(saved.filter) == "string" then
			f = Filter.withText(f, saved.filter)
		end
		for _, facet in Filter.FACETS do
			local v = saved[facet]
			if type(v) == "string" then
				(f :: any)[facet] = v
			end
		end
		s.filter = f
		if wanted == nil and type(saved.connection) == "string" then
			for i, tg in targets do
				if tg.id == saved.connection then
					s.selected = i
				end
			end
		end
		if saved.started == true then
			s.held = false
		end
	end
	local effects: { Effect } = {}
	if wanted then
		s.selected = 0
		for i, tg in targets do
			if tg.id == wanted then
				s.selected = i
			end
		end
		if s.selected == 0 then
			s.err = Errors.new(
				"query",
				string.format("no connection %q in the config (connections[])", wanted),
				Errors.NO_CONNECTION
			)
			s.held = false
			return s, effects
		end
	end
	if not s.held and #targets > 0 then
		start(s, effects)
		-- init needs no save: nothing changed yet.
		table.remove(effects)
	end
	return s, effects
end

-- Returns the same state table when the message changed nothing.
function M.update(state: State, msg: Msg): (State, { Effect })
	local s = table.clone(state)
	if state.edit then
		s.edit = table.clone(state.edit :: Edit)
	end
	local effects: { Effect } = {}
	local changed = false
	if msg.t == "key" and msg.key then
		changed = onKey(s, msg.key, effects)
	elseif msg.t == "action" and msg.act then
		changed = onAction(s, msg.act, msg.value or "", effects)
	elseif msg.t == "result" then
		changed = onResult(s, msg, effects)
	elseif msg.t == "scanned" then
		changed = onScanned(s, msg)
	elseif msg.t == "read" then
		changed = onRead(s, msg)
	elseif msg.t == "wrote" then
		changed = onWrote(s, msg)
	elseif msg.t == "resize" and msg.height then
		changed = msg.height ~= state.height or msg.width ~= state.width
		s.height = msg.height
		s.width = msg.width
	end
	if not changed then
		return state, effects
	end
	settle(s)
	return s, effects
end

function M.save(s: State): any
	local tg = M.target(s)
	return {
		v = M.SAVE_VERSION,
		connection = if tg then tg.id else nil,
		filter = s.filter.text,
		type = s.filter.type,
		status = s.filter.status,
		level = s.filter.level,
		started = not s.held,
	}
end

return M
