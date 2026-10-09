--!strict
-- Shared types of the explorer core (state.luau, rows.luau, render.luau).

local Checks = require("../sdf/checks")
local Config = require("../config")
local Link = require("./link")
local Project = require("../sdf/project")
local Resolve = require("../account/resolve")
local Snapshot = require("../sdf/snapshot")
local Symlinks = require("../sdf/symlinks")
local Upload = require("./upload")

export type Project = Project.Project
export type Finding = Checks.Finding
export type Owner = Symlinks.Owner
export type Span = { t: string, s: string? }
export type Badge = { text: string, tone: string, title: string? }

export type Tab = "projects" | "findings"

-- What enter (or a click) does on a row.
export type Target = {
	t: "detail" | "open" | "upload",
	-- detail: the project root.
	root: string?,
	-- open: absolute path, opened at `line` when set.
	path: string?,
	line: number?,
	-- open (File Cabinet files) and upload: what `u` uploads.
	owner: Owner?,
}

export type Row = {
	-- Stable within a view: selection follows it across rescans and filters.
	key: string,
	-- heading: groups the rows after it with a larger depth; note: not selectable.
	kind: "heading" | "item" | "note",
	depth: number,
	spans: { Span },
	badges: { Badge }?,
	tone: string?,
	-- Plain text the filter matches (lower-cased when filtering).
	text: string,
	target: Target?,
}

export type ScanError = { root: string, message: string }

export type Pick = { path: string, decision: Upload.Decision, objects: number }

export type Notice = { text: string, tone: string }

export type State = {
	gen: number,
	cwd: string,
	-- Absolute file whose owners the picker lists ("--pick").
	pickPath: string?,
	config: Config.Config?,
	now: number,
	cache: Resolve.Cache,
	inflight: { [string]: boolean },

	phase: "loading" | "scanning" | "ready",
	base: string?,
	repoRoot: string?,
	projectRoot: string?,
	queue: { string },
	total: number,
	done: number,
	current: string?,
	skipped: number,
	pending: { Project },
	pendingErrors: { ScanError },
	problem: string?,

	projects: { Project },
	errors: { ScanError },
	findings: { Finding },
	index: Symlinks.Index?,
	scanned: boolean,

	tab: Tab,
	detail: string?,
	picking: boolean,
	pick: Pick?,
	sel: { [string]: string },
	offset: { [string]: number },
	filters: { [string]: string },
	editing: boolean,
	-- The pane size in cells, nil until Tern reports one (lib/pane.luau).
	height: number?,
	width: number?,
	notice: Notice?,
}

export type Key = { name: string, text: string?, ctrl: boolean?, alt: boolean?, meta: boolean?, shift: boolean? }

export type Msg = {
	t: "config" | "located" | "discovered" | "scanned" | "resolved" | "key" | "click" | "resize",
	gen: number?,
	config: Config.Config?,
	now: number?,
	repoRoot: string?,
	projectRoot: string?,
	roots: { string }?,
	err: string?,
	root: string?,
	snapshot: Snapshot.Snapshot?,
	entry: Resolve.CacheEntry?,
	key: Key?,
	value: string?,
	rows: number?,
	cols: number?,
}

export type Effect = {
	t: "config" | "locate" | "discover" | "scan" | "lookup" | "open" | "copy" | "upload" | "exit",
	gen: number?,
	cwd: string?,
	base: string?,
	roots: { string }?,
	root: string?,
	authId: string?,
	-- open: path or `path:line`.
	target: string?,
	-- copy: the text and the toast that confirms it.
	text: string?,
	note: string?,
	-- upload: what the window gets (exp is set when stored).
	grant: Link.Grant?,
}

return nil
