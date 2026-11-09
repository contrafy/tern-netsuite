--!strict
-- State of the `inspect` block: reads one NetSuite record through SuiteQL
-- (read-only) and shows its fields, system notes and related records.
-- `update` returns the next state and the effects the host runs (query
-- through NsHost, read field labels, open a URL, open a related record in a
-- new pane, focus the input, save, exit). Nothing here touches `tern`.
--
-- One inspection at a time: every query carries a token (`req`) that the
-- inspection records per part; starting another inspection (a related
-- record, Back, Reload, another connection) replaces them, so late results
-- of an older one change nothing. Parts:
--   rectype   custom records: the type's table and numeric id first
--   record    SELECT * of the record; then, in parallel:
--   std       standard field labels: NetSuite's REST metadata catalog of
--             the record type (REST connections only; `l` refreshes)
--   labels    custom field labels (falls back to `labels-plain`), then
--   display   display names of the reference columns
--   notes     system notes
--   lines     transaction lines           (transactions)
--   children  transactions created from it (transactions)
--   txns      the entity's transactions    (entities)

local Catalog = require("./catalog")
local Config = require("../config")
local Connect = require("../ns/connect")
local Errors = require("../ns/errors")
local Link = require("./link")
local Queries = require("./queries")
local Record = require("./record")
local Ref = require("./ref")

type NsError = Errors.NsError
type Kind = Catalog.Kind

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

export type Env = { null: any }

export type Effect = {
	-- metadata: read field labels (NsHost.metadata); split: open `url` (a
	-- plain inspect link) in a new pane through a single-use grant.
	t: "query" | "metadata" | "browse" | "split" | "focus" | "save" | "exit",
	req: number?,
	part: string?,
	connection: string?,
	sql: string?,
	params: { any }?,
	max_rows: number?,
	-- metadata: the REST record type and whether to bypass the cache.
	record: string?,
	refresh: boolean?,
	url: string?,
	id: string?,
}

export type Msg = {
	t: "key" | "action" | "result" | "resize",
	key: Key?,
	act: string?,
	value: string?,
	-- action: shift was held (a shift-click).
	shift: boolean?,
	req: number?,
	rows: { any }?,
	-- metadata result: field labels, when NetSuite sent them, whether from
	-- the cache.
	labels: { [string]: string }?,
	fetched: number?,
	cached: boolean?,
	err: NsError?,
	height: number?,
	width: number?,
}

export type Tab = "fields" | "notes" | "related"

export type Inspection = {
	ref: Ref.Ref,
	-- The kind being read (refined by the record row); nil until a custom
	-- record URL's type is known.
	kind: Kind?,
	rectype: number?,
	fields: { Record.Field }?,
	-- No record has this id.
	missing: boolean,
	title: string?,
	labels: Record.Labels,
	-- Standard field labels by column (REST metadata catalog), when they
	-- were fetched from NetSuite and whether they came from the cache.
	std: { [string]: string },
	stdFetched: number?,
	stdCached: boolean,
	-- Why standard fields keep their column names without an error.
	stdNote: string?,
	names: { [string]: string },
	refs: { Record.Related },
	notes: { Record.Note }?,
	notesTruncated: boolean,
	lines: { Record.Line }?,
	-- Transactions pointing back (created from it / the entity's).
	back: { Record.Related }?,
	-- Part -> token of its query in flight.
	pending: { [string]: number },
	errs: { [string]: NsError },
	notice: string?,
}

export type State = {
	targets: { Target },
	selected: number,
	env: Env,
	input: string,
	editing: boolean,
	held: boolean,
	cur: Inspection?,
	-- Earlier inspections (refs), newest last.
	history: { Ref.Ref },
	tab: Tab,
	sel: { [string]: number },
	offset: { [string]: number },
	showEmpty: boolean,
	seq: number,
	-- Why the typed text or launch could not be inspected.
	problem: string?,
	height: number?,
	width: number?,
}

M.INPUT = "main.ref"
M.SAVE_VERSION = 1
M.MAX_HISTORY = 50
M.MAX_RENDER_ROWS = 200
M.SCROLLOFF = 2
M.CHROME_LINES = 10
M.MIN_VIEWPORT = 10
local TABS: { Tab } = { "fields", "notes", "related" }
M.TABS = table.freeze(TABS)

-- Accessors -----------------------------------------------------------------------

function M.target(s: State): Target?
	return s.targets[s.selected]
end

-- The label of `column`: a custom field's own name, else the record type's
-- schema title, else nil (the view shows the column name).
function M.label(cur: Inspection, column: string): string?
	local meta = cur.labels[column]
	if meta then
		return meta.label
	end
	return cur.std[column]
end

-- Fields shown on the fields tab (empty ones only when asked).
function M.visibleFields(s: State): { Record.Field }
	local cur = s.cur
	if cur == nil or cur.fields == nil then
		return {}
	end
	if s.showEmpty then
		return cur.fields :: { Record.Field }
	end
	local out: { Record.Field } = {}
	for _, f in cur.fields :: { Record.Field } do
		if f.value ~= nil then
			table.insert(out, f)
		end
	end
	return out
end

-- Every related record: what the record points at, its line items and the
-- transactions pointing back.
function M.related(s: State): { Record.Related }
	local cur = s.cur
	if cur == nil then
		return {}
	end
	local out: { Record.Related } = table.clone(cur.refs)
	if cur.lines then
		for _, r in Record.lineItems(cur.lines) do
			table.insert(out, r)
		end
	end
	if cur.back then
		for _, r in cur.back do
			table.insert(out, r)
		end
	end
	return out
end

function M.count(s: State, tab: string): number
	if tab == "fields" then
		return #M.visibleFields(s)
	elseif tab == "notes" then
		return if s.cur and s.cur.notes then #(s.cur.notes :: { Record.Note }) else 0
	end
	return #M.related(s)
end

function M.selection(s: State, tab: string): number
	return math.clamp(s.sel[tab] or 1, 1, math.max(M.count(s, tab), 1))
end

-- Whether a part of the current inspection is still loading.
function M.loading(s: State, part: string?): boolean
	local cur = s.cur
	if cur == nil then
		return false
	end
	if part then
		return cur.pending[part] ~= nil
	end
	return next(cur.pending) ~= nil
end

-- The record's page in the NetSuite UI, or nil and why not.
function M.uiUrl(s: State): (string?, string?)
	local cur, tg = s.cur, M.target(s)
	if cur == nil or tg == nil then
		return nil, "nothing is inspected"
	end
	if cur.kind == nil then
		return nil, "the record type is not known yet"
	end
	return Catalog.uiUrl(cur.kind :: Kind, cur.ref.id, tg.account_id)
end

function M.viewport(height: number?): number
	return math.max((height or 40) - M.CHROME_LINES, M.MIN_VIEWPORT)
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

-- Queries -------------------------------------------------------------------------

local function issue(s: State, cur: Inspection, part: string, q: Queries.Query?, effects: { Effect })
	local tg = M.target(s)
	if q == nil or tg == nil then
		return
	end
	s.seq += 1
	cur.pending[part] = s.seq
	table.insert(effects, {
		t = "query",
		req = s.seq,
		part = part,
		connection = tg.id,
		sql = q.sql,
		params = q.params,
		max_rows = q.max_rows,
	})
end

local function columns(cur: Inspection): { string }
	local out: { string } = {}
	for _, f in (cur.fields or {}) :: { Record.Field } do
		table.insert(out, f.column)
	end
	return out
end

local function askDisplay(s: State, cur: Inspection, effects: { Effect })
	local kind = cur.kind
	if kind == nil or #cur.refs == 0 then
		return
	end
	issue(s, cur, "display", Queries.display(kind, cur.ref.id, Record.displayColumns(cur.refs)), effects)
end

local function askRecord(s: State, cur: Inspection, effects: { Effect })
	local kind = cur.kind
	if kind == nil then
		return
	end
	local q = Queries.record(kind, cur.ref.id)
	if q == nil then
		cur.errs.record = Errors.new("query", string.format("%q is not a table the inspector can read", kind.table))
		return
	end
	issue(s, cur, "record", q, effects)
end

-- Asks for the standard field labels of the (refined) record type, or says
-- why standard fields keep their column names.
local function askLabels(s: State, cur: Inspection, effects: { Effect }, refresh: boolean)
	local tg, kind = M.target(s), cur.kind
	if tg == nil or kind == nil then
		return
	end
	if tg.transport ~= "rest" then
		cur.stdNote = string.format(
			"Standard fields show their column names: labels come from NetSuite's REST record service,"
				.. " and connection %q uses a RESTlet.",
			tg.id
		)
		return
	end
	local rest = Catalog.restType(kind)
	if rest == nil then
		cur.stdNote = string.format(
			"Standard fields show their column names: NetSuite's REST service has no single record type for %s.",
			kind.label
		)
		return
	end
	s.seq += 1
	cur.pending.std = s.seq
	table.insert(effects, {
		t = "metadata",
		req = s.seq,
		part = "std",
		connection = tg.id,
		record = rest,
		refresh = refresh,
	})
end

local function newInspection(ref: Ref.Ref): Inspection
	return {
		ref = ref,
		kind = ref.kind,
		rectype = ref.rectype,
		fields = nil,
		missing = false,
		title = nil,
		labels = {},
		std = {},
		stdFetched = nil,
		stdCached = false,
		stdNote = nil,
		names = {},
		refs = {},
		notes = nil,
		notesTruncated = false,
		lines = nil,
		back = nil,
		pending = {},
		errs = {},
		notice = nil,
	}
end

-- Starts inspecting `ref` on the selected connection.
local function begin(s: State, ref: Ref.Ref, effects: { Effect })
	local cur = newInspection(ref)
	s.cur = cur
	s.input = Ref.text(ref)
	s.problem = nil
	s.held = false
	s.editing = false
	s.tab = "fields"
	s.sel = {}
	s.offset = {}
	local tg = M.target(s)
	if tg == nil then
		cur.errs.record = Errors.new("query", "no connection is configured (connections[])", Errors.NO_CONNECTION)
		return
	end
	if ref.account and ref.account ~= string.upper(tg.account_id) then
		cur.errs.record = Errors.new(
			"query",
			string.format(
				"the URL is for account %s but connection %q reads account %s; pick a connection for %s (c)",
				ref.account,
				tg.id,
				string.upper(tg.account_id),
				ref.account
			),
			Errors.NO_CONNECTION
		)
		return
	end
	local kind = cur.kind
	if kind == nil or (kind.family == "customrecord" and cur.rectype == nil) then
		issue(s, cur, "rectype", Queries.customRecordType(cur.rectype, if kind then kind.table else nil), effects)
	else
		askRecord(s, cur, effects)
	end
end

-- Picks the connection for `account` (a pasted URL's); false when none is
-- configured for it (the current one stays and `begin` reports it).
local function selectAccount(s: State, account: string?): boolean
	if account == nil then
		return true
	end
	local tg = M.target(s)
	if tg and string.upper(tg.account_id) == account then
		return true
	end
	for i, t in s.targets do
		if string.upper(t.account_id) == account then
			s.selected = i
			return true
		end
	end
	return false
end

-- Inspects `ref`, remembering the current inspection for Back.
local function inspect(s: State, ref: Ref.Ref, effects: { Effect }, remember: boolean)
	if remember and s.cur then
		local h = table.clone(s.history)
		table.insert(h, (s.cur :: Inspection).ref)
		while #h > M.MAX_HISTORY do
			table.remove(h, 1)
		end
		s.history = h
	end
	selectAccount(s, ref.account)
	begin(s, ref, effects)
	table.insert(effects, { t = "save" })
end

local function onRecord(s: State, cur: Inspection, msg: Msg, effects: { Effect })
	local rows = msg.rows or {}
	if #rows == 0 then
		cur.missing = true
		return
	end
	local fields = Record.fields(rows[1], s.env.null)
	local kind = Record.refine(cur.kind :: Kind, fields)
	cur.kind = kind
	cur.fields = fields
	cur.title = Record.title(fields)
	cur.refs = Record.references(kind, fields, cur.labels)
	local id = cur.ref.id
	askLabels(s, cur, effects, false)
	local labels = Queries.labels(columns(cur), true)
	if labels then
		issue(s, cur, "labels", labels, effects)
	else
		askDisplay(s, cur, effects)
	end
	if #kind.notes > 0 then
		issue(s, cur, "notes", Queries.notes(id, kind.notes), effects)
	else
		cur.notes = {}
		cur.notice = "System notes need the record type's numeric id, which is unknown."
	end
	if kind.family == "transaction" then
		issue(s, cur, "lines", Queries.lines(id), effects)
		issue(s, cur, "children", Queries.children(id), effects)
	elseif kind.family == "entity" then
		issue(s, cur, "txns", Queries.entityTransactions(id), effects)
	end
end

local function onResult(s: State, msg: Msg, effects: { Effect }): boolean
	local cur = s.cur
	if cur == nil or msg.req == nil then
		return false
	end
	local part: string? = nil
	for p, req in cur.pending do
		if req == msg.req then
			part = p
		end
	end
	if part == nil then
		return false
	end
	local c = table.clone(cur)
	c.pending = table.clone(cur.pending)
	c.errs = table.clone(cur.errs)
	c.pending[part] = nil
	s.cur = c
	local err = msg.err
	local null = s.env.null
	if part == "labels" and err then
		-- Accounts differ in what customfield exposes: retry without the join.
		issue(s, c, "labels-plain", Queries.labels(columns(c), false), effects)
		return true
	end
	if err then
		c.errs[part] = err
		if part == "labels-plain" then
			askDisplay(s, c, effects)
		end
		return true
	end
	local rows = msg.rows or {}
	if part == "rectype" then
		local row = rows[1]
		local scriptid = if type(row) == "table" then Record.text(row.scriptid, null) else nil
		local rectype = if type(row) == "table" then tonumber(Record.text(row.rectype, null) or "") else nil
		if scriptid == nil or rectype == nil or not Catalog.isCustomRecord(string.lower(scriptid)) then
			c.errs.record = Errors.new(
				"query",
				if c.rectype
					then string.format("no custom record type has internal id %d", c.rectype)
					else string.format("no custom record type %q", if c.kind then (c.kind :: Kind).table else "?")
			)
			return true
		end
		c.rectype = rectype
		c.kind = Catalog.customRecord(string.lower(scriptid), Record.text(row.name, null), rectype)
		if s.input == Ref.text(c.ref) then
			s.input = string.lower(scriptid) .. ":" .. c.ref.id
		end
		askRecord(s, c, effects)
	elseif part == "record" then
		onRecord(s, c, msg, effects)
	elseif part == "labels" or part == "labels-plain" then
		c.labels = Record.labels(rows, null)
		c.refs = Record.references(c.kind :: Kind, c.fields or {}, c.labels)
		askDisplay(s, c, effects)
	elseif part == "display" then
		c.names = Record.display(rows, null)
		c.refs = Record.named(c.refs, c.names)
	elseif part == "notes" then
		c.notes = Record.notes(rows, null)
		c.notesTruncated = #rows >= Queries.MAX_NOTES
	elseif part == "lines" then
		c.lines = Record.lines(rows, null)
	elseif part == "std" then
		c.std = msg.labels or {}
		c.stdFetched = msg.fetched
		c.stdCached = msg.cached == true
	elseif part == "children" or part == "txns" then
		local back = if c.back then table.clone(c.back :: { Record.Related }) else {}
		for _, r in Record.transactions(rows, if part == "children" then "Created from this" else "Transaction", null) do
			table.insert(back, r)
		end
		c.back = back
	end
	return true
end

-- Commands ------------------------------------------------------------------------

local function submit(s: State, effects: { Effect }): boolean
	local kind = if s.cur then (s.cur :: Inspection).kind else nil
	local ref, err = Ref.parse(s.input, kind)
	if ref == nil then
		s.problem = err
		return true
	end
	if ref.account and not selectAccount(s, ref.account) then
		s.problem = string.format("no configured connection reads account %s (connections[])", ref.account)
		return true
	end
	inspect(s, ref, effects, true)
	return true
end

local function goBack(s: State, effects: { Effect }): boolean
	local n = #s.history
	if n == 0 then
		return false
	end
	local h = table.clone(s.history)
	local ref = table.remove(h) :: Ref.Ref
	s.history = h
	begin(s, ref, effects)
	table.insert(effects, { t = "save" })
	return true
end

local function reload(s: State, effects: { Effect }): boolean
	if s.cur == nil then
		return false
	end
	local tab: Tab, sel = s.tab, s.sel
	begin(s, (s.cur :: Inspection).ref, effects)
	s.tab = tab
	s.sel = sel
	return true
end

local function selectTarget(s: State, index: number, effects: { Effect }): boolean
	if s.targets[index] == nil or index == s.selected then
		return false
	end
	s.selected = index
	if s.cur and not s.held then
		local ref = table.clone((s.cur :: Inspection).ref)
		-- Another connection reads another account: drop the URL's account.
		ref.account = nil
		begin(s, ref, effects)
	end
	table.insert(effects, { t = "save" })
	return true
end

local function move(s: State, delta: number): boolean
	local n = M.count(s, s.tab)
	if n == 0 then
		return false
	end
	local sel = table.clone(s.sel)
	sel[s.tab] = math.clamp(M.selection(s, s.tab) + delta, 1, n)
	s.sel = sel
	return true
end

-- Inspects the selected related record: in place (Back returns), or with
-- `beside` in a new inspect pane, which opens through a plain inspect link
-- the host turns into a single-use grant (lib/inspector/link.luau).
local function openSelected(s: State, effects: { Effect }, beside: boolean): boolean
	if s.tab ~= "related" then
		return false
	end
	local r = M.related(s)[M.selection(s, "related")]
	if r == nil then
		return false
	end
	local kind = Catalog.find(r.record)
	if kind == nil then
		return false
	end
	if beside then
		local tg = M.target(s)
		if tg == nil then
			return false
		end
		table.insert(effects, { t = "split", url = Link.url({ connection = tg.id, type = kind.record, id = r.id }) })
		return false
	end
	inspect(s, { kind = kind, id = r.id, rectype = nil, account = nil }, effects, true)
	return true
end

-- Reads the standard field labels from NetSuite again, past the cache; the
-- labels shown stay until the new ones arrive.
local function refreshLabels(s: State, effects: { Effect }): boolean
	local cur = s.cur
	if cur == nil or cur.fields == nil or s.held then
		return false
	end
	local c = table.clone(cur)
	c.pending = table.clone(cur.pending)
	local errs: { [string]: NsError } = {}
	for part, e in cur.errs do
		if part ~= "std" then
			errs[part] = e
		end
	end
	c.errs = errs
	c.stdNote = nil
	s.cur = c
	askLabels(s, c, effects, true)
	return true
end

local function browse(s: State, effects: { Effect }): boolean
	local url, why = M.uiUrl(s)
	if url == nil then
		s.problem = why
		return true
	end
	table.insert(effects, { t = "browse", url = url })
	return false
end

local function cycleTab(s: State, delta: number)
	local i = table.find(M.TABS, s.tab) or 1
	s.tab = M.TABS[(i - 1 + delta) % #M.TABS + 1]
end

local function startEdit(s: State, effects: { Effect })
	s.editing = true
	table.insert(effects, { t = "focus", id = M.INPUT })
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
	return nil
end

local function editKey(s: State, key: Key, effects: { Effect }): boolean
	local name = key.name
	if name == "escape" then
		s.editing = false
	elseif name == "enter" or name == "return" then
		return submit(s, effects)
	elseif name == "backspace" then
		if s.input == "" then
			return false
		end
		s.input = string.sub(s.input, 1, (utf8.offset(s.input, -1) or #s.input) - 1)
	elseif name == "u" and key.ctrl then
		s.input = ""
	elseif name == "paste" and type(key.text) == "string" then
		s.input = s.input .. (string.gsub(key.text, "%c", ""))
	else
		local ch = printable(key)
		if ch == nil then
			return false
		end
		s.input = s.input .. ch
	end
	s.problem = nil
	return true
end

local function start(s: State, effects: { Effect }): boolean
	local cur = s.cur
	if cur == nil then
		return false
	end
	begin(s, cur.ref, effects)
	table.insert(effects, { t = "save" })
	return true
end

local function heldKey(s: State, key: Key, effects: { Effect }): boolean
	if key.ctrl or key.meta or key.alt then
		return false
	elseif key.name == "escape" then
		table.insert(effects, { t = "exit" })
		return false
	elseif key.name == "enter" or key.name == "return" then
		return start(s, effects)
	end
	return false
end

local function onKey(s: State, key: Key, effects: { Effect }): boolean
	if s.held then
		return heldKey(s, key, effects)
	end
	if s.editing then
		return editKey(s, key, effects)
	end
	local name = key.name
	local ch = printable(key)
	local page = M.viewport(s.height)
	if name == "escape" then
		table.insert(effects, { t = "exit" })
		return false
	elseif ch == "j" or name == "down" then
		return move(s, 1)
	elseif ch == "k" or name == "up" then
		return move(s, -1)
	elseif name == "page_down" then
		return move(s, page)
	elseif name == "page_up" then
		return move(s, -page)
	elseif ch == "g" or name == "home" then
		return move(s, -math.huge)
	elseif ch == "G" or name == "end" then
		return move(s, math.huge)
	elseif name == "tab" then
		cycleTab(s, if key.shift then -1 else 1)
	elseif ch == "1" or ch == "2" or ch == "3" then
		s.tab = M.TABS[tonumber(ch) :: number]
	elseif name == "enter" or name == "return" then
		return openSelected(s, effects, key.shift == true)
	elseif ch == "/" or ch == "i" then
		startEdit(s, effects)
	elseif ch == "o" then
		return browse(s, effects)
	elseif ch == "r" then
		return reload(s, effects)
	elseif ch == "l" then
		return refreshLabels(s, effects)
	elseif ch == "b" or name == "backspace" then
		return goBack(s, effects)
	elseif ch == "e" then
		s.showEmpty = not s.showEmpty
	elseif ch == "c" then
		if #s.targets == 0 then
			return false
		end
		return selectTarget(s, s.selected % #s.targets + 1, effects)
	else
		return false
	end
	return true
end

local function onAction(s: State, act: string, value: string, shift: boolean, effects: { Effect }): boolean
	if s.held then
		if act == "start" then
			return start(s, effects)
		elseif act == "close" then
			table.insert(effects, { t = "exit" })
		end
		return false
	end
	if act == "tab" then
		if table.find(M.TABS, value :: any) == nil or s.tab == value then
			return false
		end
		s.tab = value :: Tab
	elseif act == "sel" or act == "go" then
		local i = tonumber(value)
		if i == nil or i < 1 or i > M.count(s, s.tab) then
			return false
		end
		local sel = table.clone(s.sel)
		sel[s.tab] = i
		s.sel = sel
		if act == "go" then
			openSelected(s, effects, shift)
		end
	elseif act == "open-ui" then
		return browse(s, effects)
	elseif act == "reload" then
		return reload(s, effects)
	elseif act == "back" then
		return goBack(s, effects)
	elseif act == "labels" then
		return refreshLabels(s, effects)
	elseif act == "empty" then
		s.showEmpty = not s.showEmpty
	elseif act == "conn" then
		for i, tg in s.targets do
			if tg.id == value then
				return selectTarget(s, i, effects)
			end
		end
		return false
	elseif act == "input-focus" then
		if s.editing then
			return false
		end
		startEdit(s, effects)
	elseif act == "submit" then
		return submit(s, effects)
	elseif act == "close" then
		table.insert(effects, { t = "exit" })
		return false
	else
		return false
	end
	return true
end

-- Keeps every tab's selection in range and its window around it.
local function settle(s: State)
	local sel, offset = table.clone(s.sel), table.clone(s.offset)
	for _, tab in M.TABS do
		local n = M.count(s, tab)
		local i = math.clamp(sel[tab] or 1, 1, math.max(n, 1))
		sel[tab] = i
		offset[tab] = M.window(i, n, offset[tab] or 1, M.MAX_RENDER_ROWS)
	end
	s.sel, s.offset = sel, offset
end

-- Init / update -------------------------------------------------------------------

-- Block args naming `ref` (Link.toArgs), e.g. for the saved state.
function M.refArgs(ref: Ref.Ref): { string }
	return Link.toArgs({
		connection = nil,
		type = if ref.kind then ref.kind.record else nil,
		id = ref.id,
		rectype = if ref.kind then nil else ref.rectype,
		account = ref.account,
		hold = nil,
	})
end

local function launchRef(launch: Link.Launch): Ref.Ref?
	if launch.id == nil then
		return nil
	end
	if launch.type then
		local kind = Catalog.find(launch.type :: string)
		if kind == nil then
			return nil
		end
		return { kind = kind, id = launch.id :: string, rectype = nil, account = launch.account }
	elseif launch.rectype then
		return { kind = nil, id = launch.id :: string, rectype = launch.rectype, account = launch.account }
	end
	return nil
end

function M.init(args: { string }, saved: any, cfg: Config.Config, env: Env): (State, { Effect })
	local launch, problems = Link.fromArgs(args)
	local targets = Connect.targets(cfg)
	local s: State = {
		targets = targets,
		selected = if #targets > 0 then 1 else 0,
		env = env,
		input = "",
		editing = false,
		held = false,
		cur = nil,
		history = {},
		tab = "fields",
		sel = {},
		offset = {},
		showEmpty = false,
		seq = 0,
		problem = if #problems > 0 then "Ignored launch arguments: " .. table.concat(problems, "; ") else nil,
		height = nil,
		width = nil,
	}
	local effects: { Effect } = {}
	local ref = launchRef(launch)
	local started = false
	if type(saved) == "table" and saved.v == M.SAVE_VERSION then
		if launch.connection == nil and launch.account == nil and type(saved.connection) == "string" then
			for i, tg in targets do
				if tg.id == saved.connection then
					s.selected = i
				end
			end
		end
		if ref == nil and type(saved.ref) == "table" then
			local savedArgs: { string } = {}
			for _, a in saved.ref do
				if type(a) == "string" and a ~= Link.HOLD_ARG then
					table.insert(savedArgs, a)
				end
			end
			local restored, bad = Link.fromArgs(savedArgs)
			if #bad == 0 then
				ref = launchRef(restored)
			end
		end
		started = saved.started == true
		if type(saved.input) == "string" then
			s.input = saved.input
		end
	end
	if launch.connection then
		s.selected = 0
		for i, tg in targets do
			if tg.id == launch.connection then
				s.selected = i
			end
		end
		if s.selected == 0 then
			s.problem = string.format("no connection %q in the config (connections[])", launch.connection)
			return s, effects
		end
	elseif ref and ref.account and not selectAccount(s, ref.account) then
		s.problem = string.format("no configured connection reads account %s (connections[])", ref.account)
		s.input = Ref.text(ref)
		return s, effects
	end
	if ref == nil then
		if launch.id then
			s.input = launch.id
			s.problem = "add the record type: type:" .. launch.id .. " (e.g. salesorder:" .. launch.id .. ")"
		end
		if #targets > 0 then
			startEdit(s, effects)
		end
		return s, effects
	end
	s.input = Ref.text(ref)
	if launch.hold and not started then
		-- Opened from a plain link: show what would be read, wait for Enter.
		s.cur = newInspection(ref)
		s.held = true
		return s, effects
	end
	begin(s, ref, effects)
	return s, effects
end

-- Returns the same state table when the message changed nothing.
function M.update(state: State, msg: Msg): (State, { Effect })
	local s = table.clone(state)
	local effects: { Effect } = {}
	local changed = false
	if msg.t == "key" and msg.key then
		changed = onKey(s, msg.key, effects)
	elseif msg.t == "action" and msg.act then
		changed = onAction(s, msg.act, msg.value or "", msg.shift == true, effects)
	elseif msg.t == "result" then
		changed = onResult(s, msg, effects)
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
		ref = if s.cur then M.refArgs((s.cur :: Inspection).ref) else nil,
		input = s.input,
		started = s.cur ~= nil and not s.held,
	}
end

return M
