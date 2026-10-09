--!strict
-- The rows of each explorer view, as plain data: render.luau draws a window
-- of them and state.luau moves the selection over the selectable ones (rows
-- with a target). Filtering keeps a heading whenever a row under it matches.

local Project = require("../sdf/project")
local Resolve = require("../account/resolve")
local Types = require("./types")
local Upload = require("./upload")

type State = Types.State
type Row = Types.Row
type Span = Types.Span
type Badge = Types.Badge
type Project = Types.Project
type Finding = Types.Finding
type Owner = Types.Owner

local M = {}

local SEVERITY_RANK: { [string]: number } = { error = 1, warning = 2, info = 3 }
local SEVERITY_TONE: { [string]: string } = { error = "error", warning = "warning", info = "muted" }
local SEVERITY_TAG: { [string]: string } = { error = "E", warning = "W", info = "I" }

M.COLLISION = "cross-project-collision"

local function join(root: string, rel: string): string
	return if string.sub(rel, 1, 1) == "/" then rel else root .. "/" .. rel
end

function M.relative(base: string?, path: string): string
	if base and base ~= "/" and string.sub(path, 1, #base + 1) == base .. "/" then
		return string.sub(path, #base + 2)
	end
	return path
end

local function plural(n: number, word: string, many: string?): string
	return string.format("%d %s", n, if n == 1 then word else (many or word .. "s"))
end

local function textOf(spans: { Span }, badges: { Badge }?): string
	local parts: { string } = {}
	for _, s in spans do
		table.insert(parts, s.t)
	end
	if badges then
		for _, b in badges do
			table.insert(parts, " " .. b.text)
		end
	end
	return table.concat(parts)
end

type RowExtra = {
	badges: { Badge }?,
	tone: string?,
	target: Types.Target?,
}

local function row(
	key: string,
	kind: "heading" | "item" | "note",
	depth: number,
	spans: { Span },
	extra: RowExtra?
): Row
	local e: RowExtra = extra or {}
	return {
		key = key,
		kind = kind,
		depth = depth,
		spans = spans,
		badges = e.badges,
		tone = e.tone,
		text = textOf(spans, e.badges),
		target = e.target,
	}
end

local function span(t: string, s: string?): Span
	return if s then { t = t, s = s } else { t = t }
end

function M.resolveOpts(s: State): Resolve.Options?
	if s.config == nil then
		return nil
	end
	return { config = s.config, cache = s.cache, now = s.now }
end

function M.target(s: State, authId: string?): Upload.Target
	local opts = M.resolveOpts(s)
	if opts == nil then
		return { authId = authId, label = authId or "no auth id", production = true, source = "unknown" }
	end
	return Upload.target(authId, opts)
end

function M.accountBadge(s: State, p: Project): Badge
	local authId = p.defaultAuthId
	if authId == nil then
		return { text = "no auth id", tone = "muted", title = "project.json has no defaultAuthId: the CLI asks" }
	end
	local target = M.target(s, authId)
	if target.source == "unknown" then
		local entry = s.cache[authId]
		if entry and entry.error then
			return {
				text = authId .. (if string.find(string.upper(authId), "PROD", 1, true) then "?" else "? PROD"),
				tone = "error",
				title = "manageauth --info failed (" .. entry.error .. "); counts as production",
			}
		end
		return {
			text = authId .. "?",
			tone = "warning",
			title = "Auth ID not resolved yet; counts as production until it is",
		}
	end
	if target.production then
		local label = if string.find(string.upper(target.label), "PROD", 1, true)
			then target.label
			else target.label .. " PROD"
		return { text = label, tone = "error", title = "Production account (" .. (target.accountId or "?") .. ")" }
	end
	return { text = target.label, tone = "success", title = authId .. " -> " .. (target.accountId or "?") }
end

export type Counts = { error: number, warning: number, info: number }

function M.counts(findings: { Finding }, project: string): Counts
	local c: Counts = { error = 0, warning = 0, info = 0 }
	for _, f in findings do
		if f.project == project then
			local sev = f.severity :: string
			if sev == "error" or sev == "warning" or sev == "info" then
				(c :: any)[sev] += 1
			end
		end
	end
	return c
end

-- Project list ----------------------------------------------------------------

local function projectRows(s: State): { Row }
	local out: { Row } = {}
	local names: { [string]: number } = {}
	for _, p in s.projects do
		names[p.name] = (names[p.name] or 0) + 1
	end
	for _, p in s.projects do
		local c = M.counts(s.findings, p.name)
		local spans: { Span } = { span(p.name, "strong") }
		-- The directory only tells same-named projects apart (detail shows it).
		if names[p.name] > 1 then
			table.insert(spans, span("  " .. M.relative(s.base, p.root), "muted"))
		end
		table.insert(spans, span(string.format("  %s · %s", plural(#p.objects, "object"), plural(#p.files, "file"))))
		if c.error > 0 then
			table.insert(spans, span("  " .. plural(c.error, "error"), "error"))
		end
		if c.warning > 0 then
			table.insert(spans, span("  " .. plural(c.warning, "warning"), "warning"))
		end
		if c.info > 0 then
			table.insert(spans, span("  " .. c.info .. " info", "muted"))
		end
		if p.truncated then
			table.insert(spans, span("  truncated (projects.max_files)", "warning"))
		end
		table.insert(
			out,
			row("p:" .. p.root, "item", 0, spans, {
				badges = { M.accountBadge(s, p) },
				target = { t = "detail", root = p.root },
			})
		)
	end
	for _, e in s.errors do
		table.insert(
			out,
			row(
				"e:" .. e.root,
				"note",
				0,
				{ span(M.relative(s.base, e.root), "strong"), span("  " .. e.message, "error") }
			)
		)
	end
	if #out == 0 and s.phase == "ready" then
		table.insert(
			out,
			row("none", "note", 0, {
				span(
					"No SDF projects (suitecloud.config.js) under "
						.. (s.base or s.cwd)
						.. (if s.problem then ": " .. s.problem else ""),
					"muted"
				),
			})
		)
	end
	return out
end

-- Project detail --------------------------------------------------------------

local function fileOwner(p: Project, f: Project.File): Owner
	return { project = p.name, root = p.root, path = f.path, fileCabinetPath = f.fileCabinetPath }
end

local function deploymentSpans(d: Project.Deployment): { Span }
	local spans: { Span } = { span("↳ ", "muted"), span(d.scriptId, "mono") }
	if d.status then
		table.insert(spans, span("  " .. d.status, if d.status == "RELEASED" then nil else "warning"))
	end
	if d.logLevel then
		table.insert(spans, span("  " .. d.logLevel, "muted"))
	end
	if d.isDeployed == false then
		table.insert(spans, span("  not deployed", "warning"))
	end
	if d.recordType then
		table.insert(spans, span("  " .. d.recordType, "muted"))
	end
	return spans
end

local function objectRows(p: Project, out: { Row })
	table.insert(out, row("h:objects", "heading", 0, { span(string.format("Objects (%d)", #p.objects), "strong") }))
	local byType: { [string]: { Project.SdfObject } } = {}
	local types: { string } = {}
	for _, o in p.objects do
		local list = byType[o.type]
		if list == nil then
			list = {}
			byType[o.type] = list
			table.insert(types, o.type)
		end
		table.insert(list, o)
	end
	table.sort(types)
	for _, ty in types do
		local list = byType[ty]
		table.sort(list, function(a: Project.SdfObject, b: Project.SdfObject): boolean
			return a.scriptId < b.scriptId
		end)
		table.insert(out, row("h:type:" .. ty, "heading", 1, { span(string.format("%s (%d)", ty, #list), "accent") }))
		for _, o in list do
			local path = join(p.root, o.path)
			local spans: { Span } = { span(o.scriptId, "mono strong") }
			if o.isScript and o.fileReferences[1] then
				table.insert(spans, span("  " .. o.fileReferences[1].path, "muted"))
			end
			if #o.deployments > 0 then
				table.insert(spans, span("  " .. plural(#o.deployments, "deployment"), "muted"))
			end
			table.insert(
				out,
				row("o:" .. o.path, "item", 2, spans, { target = { t = "open", path = path, line = o.line } })
			)
			for _, d in o.deployments do
				table.insert(
					out,
					row(
						"d:" .. o.path .. ":" .. d.scriptId .. ":" .. d.line,
						"item",
						3,
						deploymentSpans(d),
						{ target = { t = "open", path = path, line = d.line } }
					)
				)
			end
		end
	end
end

local function cabinetRows(p: Project, base: string?, out: { Row })
	table.insert(out, row("h:files", "heading", 0, { span(string.format("File Cabinet (%d)", #p.files), "strong") }))
	local files = table.clone(p.files)
	table.sort(files, function(a: Project.File, b: Project.File): boolean
		return a.fileCabinetPath < b.fileCabinetPath
	end)
	local open: { string } = {}
	for _, f in files do
		local parts = string.split(string.sub(f.fileCabinetPath, 2), "/")
		local name = table.remove(parts) :: string
		local same = 0
		while same < #open and same < #parts and open[same + 1] == parts[same + 1] do
			same += 1
		end
		for i = #open, same + 1, -1 do
			open[i] = nil
		end
		for i = same + 1, #parts do
			open[i] = parts[i]
			table.insert(
				out,
				row("h:dir:/" .. table.concat(parts, "/", 1, i), "heading", i, { span(parts[i] .. "/", "accent") })
			)
		end
		local spans: { Span } = { span(name) }
		if f.real then
			table.insert(spans, span("  → " .. M.relative(base, f.real), "muted"))
		end
		if not Project.isDeployed(p, "files", f.path) then
			table.insert(spans, span("  not in deploy.xml", "warning"))
		end
		table.insert(
			out,
			row("f:" .. f.path, "item", #parts + 1, spans, {
				target = { t = "open", path = join(p.root, f.path), owner = fileOwner(p, f) },
			})
		)
	end
end

local function manifestRows(p: Project, out: { Row })
	local m = p.manifest
	table.insert(out, row("h:manifest", "heading", 0, { span("Manifest dependencies", "strong") }))
	if m == nil then
		table.insert(out, row("m:none", "note", 1, { span("no manifest.xml", "warning") }))
		return
	end
	local target: Types.Target = { t = "open", path = join(p.root, m.path) }
	local deps = m.dependencies
	local n = 0
	for _, f in deps.features do
		n += 1
		table.insert(
			out,
			row("m:feature:" .. f.name, "item", 1, {
				span("feature ", "muted"),
				span(f.name, "mono"),
				span(if f.required then "  required" else "  optional", "muted"),
			}, { target = target })
		)
	end
	for _, id in deps.objects do
		n += 1
		table.insert(
			out,
			row("m:object:" .. id, "item", 1, { span("object ", "muted"), span(id, "mono") }, { target = target })
		)
	end
	for _, path in deps.files do
		n += 1
		table.insert(
			out,
			row("m:file:" .. path, "item", 1, { span("file ", "muted"), span(path, "mono") }, { target = target })
		)
	end
	local groups: { { word: string, list: { Project.DependencyGroup } } } = {
		{ word = "application", list = deps.applications },
		{ word = "bundle", list = deps.bundles },
	}
	for _, group in groups do
		for _, g in group.list do
			n += 1
			table.insert(
				out,
				row("m:" .. group.word .. ":" .. g.id, "item", 1, {
					span(group.word .. " ", "muted"),
					span(g.id, "mono"),
					span(string.format("  %s, %s", plural(#g.objects, "object"), plural(#g.files, "file")), "muted"),
				}, { target = target })
			)
		end
	end
	if n == 0 then
		table.insert(out, row("m:empty", "note", 1, { span("none declared", "muted") }))
	end
end

local function deployRows(p: Project, out: { Row })
	local d = p.deploy
	table.insert(
		out,
		row(
			"h:deploy",
			"heading",
			0,
			{ span(string.format("deploy.xml paths (%d)", if d then #d.paths else 0), "strong") }
		)
	)
	if d == nil then
		table.insert(out, row("x:none", "note", 1, { span("no deploy.xml", "warning") }))
		return
	end
	local path = join(p.root, d.path)
	for i, dp in d.paths do
		table.insert(
			out,
			row("x:" .. i, "item", 1, {
				span(dp.section, "muted"),
				span("  " .. dp.pattern, "mono"),
			}, { target = { t = "open", path = path, line = dp.line } })
		)
	end
end

function M.project(s: State, root: string): Project?
	for _, p in s.projects do
		if p.root == root then
			return p
		end
	end
	return nil
end

local function detailRows(s: State, p: Project): { Row }
	local out: { Row } = {}
	local target = M.target(s, p.defaultAuthId)
	table.insert(
		out,
		row("i:root", "note", 0, { span("root ", "muted"), span(p.root, "mono") }, {
			badges = { M.accountBadge(s, p) },
		})
	)
	table.insert(
		out,
		row("i:auth", "note", 0, {
			span("auth ", "muted"),
			span(p.defaultAuthId or "none", "mono"),
			span(
				"  → "
					.. target.label
					.. (
						if target.accountId and target.accountId ~= target.label
							then " (" .. target.accountId .. ")"
							else ""
					),
				"muted"
			),
		})
	)
	local m = p.manifest
	if m then
		table.insert(
			out,
			row("i:manifest", "note", 0, {
				span("manifest ", "muted"),
				span(table.concat({ m.projectType or "?", m.projectName or "", m.projectVersion or "" }, " ")),
			})
		)
	end
	if p.truncated then
		table.insert(
			out,
			row("i:truncated", "note", 0, { span("Only the first files were scanned (projects.max_files)", "warning") })
		)
	end
	objectRows(p, out)
	cabinetRows(p, s.base, out)
	manifestRows(p, out)
	deployRows(p, out)
	return out
end

-- Findings --------------------------------------------------------------------

local function rootOf(s: State, name: string): string?
	for _, p in s.projects do
		if p.name == name then
			return p.root
		end
	end
	return nil
end

local function findingRows(s: State): { Row }
	local out: { Row } = {}
	local groups: { [string]: { Finding } } = {}
	local codes: { string } = {}
	local worst: { [string]: number } = {}
	for _, f in s.findings do
		local list = groups[f.code]
		if list == nil then
			list = {}
			groups[f.code] = list
			table.insert(codes, f.code)
			worst[f.code] = 3
		end
		table.insert(list, f)
		worst[f.code] = math.min(worst[f.code], SEVERITY_RANK[f.severity] or 3)
	end
	table.sort(codes, function(a: string, b: string): boolean
		if worst[a] ~= worst[b] then
			return worst[a] < worst[b]
		end
		return a < b
	end)
	for _, code in codes do
		local list = groups[code]
		local collision = code == M.COLLISION
		table.insert(
			out,
			row("h:" .. code, "heading", 0, {
				span(code, "strong"),
				span(string.format("  %d", #list), "muted"),
				if collision then span("  same file shipped by several projects", "warning") else span(""),
			}, { tone = if collision then "warning" else nil })
		)
		for i, f in list do
			local root = rootOf(s, f.project)
			local where = if f.path then f.path .. (if f.line then ":" .. f.line else "") else ""
			local spans: { Span } = {
				span(SEVERITY_TAG[f.severity] or "?", SEVERITY_TONE[f.severity]),
				span("  " .. f.project, "strong"),
				span("  " .. where, "mono"),
				span("  " .. f.message, if collision then "warning" else nil),
			}
			local target: Types.Target? = if root and f.path
				then { t = "open", path = join(root, f.path), line = f.line }
				else nil
			table.insert(out, row("g:" .. code .. ":" .. i, "item", 1, spans, { target = target }))
		end
	end
	if #out == 0 and s.phase == "ready" then
		table.insert(out, row("none", "note", 0, { span("No findings", "muted") }))
	end
	return out
end

-- Picker ----------------------------------------------------------------------

local function pickRows(s: State): { Row }
	local out: { Row } = {}
	local pick = s.pick
	if pick == nil then
		return out
	end
	local d = pick.decision
	table.insert(out, row("h:pick", "heading", 0, { span("Upload ", "strong"), span(pick.path, "mono") }))
	if d.t == "none" then
		table.insert(out, row("k:none", "note", 1, { span("Nothing to upload: " .. (d.reason or ""), "warning") }))
		return out
	end
	for _, o in d.owners do
		local p = M.project(s, o.root)
		local badges = if p then { M.accountBadge(s, p) } else nil
		table.insert(
			out,
			row("k:" .. o.root .. ":" .. o.path, "item", 1, {
				span(o.project, "strong"),
				span("  " .. (o.fileCabinetPath or o.path), "mono"),
			}, { badges = badges, target = { t = "upload", owner = o } })
		)
	end
	if pick.objects > 0 then
		table.insert(
			out,
			row("k:objects", "note", 1, {
				span(
					plural(pick.objects, "project carries", "projects carry") .. " it as an object (project:deploy)",
					"muted"
				),
			})
		)
	end
	return out
end

-- Assembly --------------------------------------------------------------------

function M.viewKey(s: State): string
	if s.picking then
		return "pick"
	end
	if s.tab == "findings" then
		return "findings"
	end
	if s.detail then
		return "detail:" .. s.detail
	end
	return "projects"
end

function M.unfiltered(s: State): { Row }
	if s.picking then
		return pickRows(s)
	end
	if s.tab == "findings" then
		return findingRows(s)
	end
	if s.detail then
		local p = M.project(s, s.detail)
		if p then
			return detailRows(s, p)
		end
	end
	return projectRows(s)
end

-- Rows matching `filter` (case-insensitive substring), with the headings
-- above each kept row.
function M.filter(rows: { Row }, filter: string?): { Row }
	if filter == nil or filter == "" then
		return rows
	end
	local needle = string.lower(filter)
	local out: { Row } = {}
	local stack: { { row: Row, shown: boolean } } = {}
	for _, r in rows do
		if r.kind == "heading" then
			while #stack > 0 and stack[#stack].row.depth >= r.depth do
				table.remove(stack)
			end
			table.insert(stack, { row = r, shown = false })
		elseif string.find(string.lower(r.text), needle, 1, true) then
			for _, h in stack do
				if not h.shown then
					h.shown = true
					table.insert(out, h.row)
				end
			end
			table.insert(out, r)
		end
	end
	return out
end

function M.build(s: State): { Row }
	return M.filter(M.unfiltered(s), s.filters[M.viewKey(s)])
end

-- Lines `text` takes at `width` columns when the first line starts at
-- column `indent`, wrapping words greedily; a word longer than a line
-- starts on a new line and breaks anywhere. Errs on the high side.
function M.wrap(text: string, width: number, indent: number?): number
	-- Cells the renderer keeps for padding.
	local w = math.max(width - 2, 8)
	local lines = 1
	local col = indent or 0
	for word in string.gmatch(text, "%S+") do
		local n = utf8.len(word) or #word
		local need = if col == 0 then n else col + 1 + n
		if need <= w then
			col = need
		elseif n <= w then
			lines += 1
			col = n
		else
			if col > 0 then
				lines += 1
			end
			lines += math.ceil(n / w) - 1
			col = n - (math.ceil(n / w) - 1) * w
		end
	end
	return lines
end

-- Terminal lines a row takes at `width` columns (marker, indentation and
-- badge padding included): long rows such as findings wrap in narrow panes,
-- so the window is measured in lines, not rows.
function M.lines(r: Row, width: number): number
	local text = r.text
	if r.badges then
		-- Pill padding.
		text ..= string.rep(" xx", #r.badges)
	end
	return M.wrap(text, width, 2 + 2 * r.depth)
end

-- First and last index of the rows to draw in `budget` lines: the window
-- starts at the previous first row `offset` and scrolls only as far as
-- needed to show `selected`. It always holds at least the selected row.
function M.window(rows: { Row }, selected: number, offset: number?, budget: number, width: number): (number, number)
	local total = #rows
	if total == 0 then
		return 1, 0
	end
	local sel = math.clamp(selected, 1, total)
	local first = math.clamp(offset or 1, 1, total)
	if sel < first then
		first = sel
	end
	local used = 0
	local last = first - 1
	while last < total do
		local h = M.lines(rows[last + 1], width)
		if last >= first and used + h > budget then
			break
		end
		used += h
		last += 1
	end
	if sel > last then
		first, last = sel, sel
		used = M.lines(rows[sel], width)
	end
	-- Fill the space left at the end of the list with rows above.
	while first > 1 and used + M.lines(rows[first - 1], width) <= budget do
		first -= 1
		used += M.lines(rows[first], width)
	end
	return first, last
end

return table.freeze(M)
