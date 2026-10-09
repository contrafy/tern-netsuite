--!strict
-- Host adapter of lens `suitecloud`: records the output of a claimed
-- SuiteCloud CLI run and renders lib/lens views once it finishes.

local Argv = require("./lib/sdf/argv")
local ConfigHost = require("./config_host")
local Link = require("./lib/browser/link")
local LogsLink = require("./lib/monitor/logs/link")
local Manageauth = require("./lib/lens/manageauth")
local Output = require("./lib/sdf/output")
local View = require("./lib/lens/view")
local Viewstate = require("./lib/lens/viewstate")

local log = tern.log

type ViewState = Viewstate.ViewState

-- open/line/finish only record: Tern replays them on rehydration, so they
-- must stay side-effect free. Everything else happens in view/event.
type LensState = {
	run: LensRun,
	inv: Argv.Invocation?,
	lines: { string },
	bytes: number,
	-- Output beyond the configured caps: the lens stops recording, stays raw.
	overflow: boolean,
	status: number?,
	result: Output.Result?,
	view: ViewState,
	warned: boolean,
	native: boolean,
	maxLines: number,
	maxBytes: number,
	-- `~/` base folder, read from cwd's suitecloud.config.js on the first
	-- view; false when unknown (links are then omitted).
	projectDir: string | false | nil,
}

local M = {}

local function warnOnce(state: LensState, what: string, err: any)
	if not state.warned then
		state.warned = true
		log.warn("tern-netsuite lens " .. what .. " failed; showing raw", state.run.line, tostring(err))
	end
end

local function absolute(path: string?): string?
	return if path and string.sub(path, 1, 1) == "/" then path else nil
end

-- Far above any real suitecloud.config.js.
local MAX_CONFIG_BYTES = 65536

-- I/O in a lens callback: done once per run, from view (never open/line/
-- finish, which Tern replays), and any failure just leaves paths unlinked.
local function projectDir(state: LensState, cwd: string): string?
	local known = state.projectDir
	if known == nil then
		local ok, text = pcall(tern.fs.read, cwd .. "/suitecloud.config.js", MAX_CONFIG_BYTES)
		local dir = if ok then View.projectDir(cwd, text) else nil
		state.projectDir = dir or false
		return dir
	end
	return if type(known) == "string" then known else nil
end

local function options(state: LensState): View.Options
	local cwd = absolute(state.run.cwd)
	local inv = state.inv
	-- A wrapper may run from elsewhere (`--project x`), so its paths stay
	-- unlinked.
	local direct = inv ~= nil and inv.viaWrapper == nil
	return {
		cfg = ConfigHost.current(),
		cwd = cwd,
		projectDir = if direct and cwd then projectDir(state, cwd) else nil,
		line = if state.run.typed ~= "" then state.run.typed else state.run.line,
	}
end

local function resultOf(state: LensState): Output.Result?
	if state.result then
		return state.result
	end
	local inv = state.inv
	if inv == nil or state.status == nil then
		return nil
	end
	state.result = Output.parse(inv, state.lines, state.status)
	return state.result
end

local function render(state: LensState): Node?
	local inv = state.inv
	-- Results are only meaningful whole: the view stays raw while it runs.
	if inv == nil or state.status == nil or state.overflow then
		return nil
	end
	if inv.command == "account:manageauth" then
		return Manageauth.render(inv, state.lines, ConfigHost.current()) :: any
	end
	if inv.command == "object:list" or inv.command == "file:list" then
		return View.renderListing(inv, state.lines, state.status :: number, state.view, options(state)) :: any
	end
	local result = resultOf(state)
	if result == nil then
		return nil
	end
	return View.render(result, inv, state.view, options(state)) :: any
end

local function copy(state: LensState, what: string, cx: EffectCx)
	local inv = state.inv
	local result = resultOf(state)
	if inv == nil or result == nil then
		return
	end
	local text = View.copyText(result, inv, what)
	if text == nil then
		cx:toast("error", "Nothing to copy")
		return
	end
	cx:copy(text)
	local first = string.match(text, "^[^\n]*") or text
	cx:toast("success", "Copied", first)
end

function M.register()
	tern.lens.define("suitecloud", {
		open = function(run: LensRun, _cx: EffectCx): LensState
			local cfg = ConfigHost.current()
			return {
				run = run,
				inv = Argv.parse(run, cfg.lens.wrappers),
				lines = {},
				bytes = 0,
				overflow = false,
				status = nil,
				result = nil,
				view = Viewstate.default(),
				warned = false,
				native = cfg.general.native_default,
				maxLines = cfg.general.max_lines,
				maxBytes = cfg.general.max_capture_bytes,
				projectDir = nil,
			}
		end,
		line = function(state: LensState, l: LensLine)
			if state.overflow then
				return
			end
			state.bytes += #l.text + 1
			if #state.lines >= state.maxLines or state.bytes > state.maxBytes then
				state.overflow = true
				state.lines = {}
				return
			end
			table.insert(state.lines, l.text)
		end,
		finish = function(state: LensState, status: number)
			state.status = status
			state.result = nil
		end,
		view = function(state: LensState): Node?
			if not state.native then
				return nil
			end
			local ok, node = pcall(render, state)
			if not ok then
				warnOnce(state, "view", node)
				return nil
			end
			return node
		end,
		event = function(state: LensState, ev: UiEvent, cx: EffectCx)
			if ev.ev ~= "action" then
				return
			end
			local value: string = if type(ev.value) == "string" then ev.value else ""
			local ok, err = pcall(function()
				if ev.act == "v" then
					state.view = Viewstate.decode(value)
				elseif ev.act == "copy" then
					copy(state, value, cx)
				elseif ev.act == "logs" then
					-- Only a link the window's logs route accepts reaches cx:open.
					local decision = LogsLink.route(value)
					if decision then
						cx:open(value)
					end
				elseif ev.act == View.BROWSE_ACTION then
					cx:open(Link.browseUrl(absolute(state.run.cwd)))
				end
			end)
			if not ok then
				warnOnce(state, "event " .. tostring(ev.act), err)
			end
		end,
	})
end

return M
