--!strict
-- The native view of `account:manageauth --list` (a table of auth IDs) and
-- `--info <authId>` (one account), each account marked production or not
-- by Classify. Other manageauth options (--remove, --rename) stay raw.

local Argv = require("../sdf/argv")
local Classify = require("../account/classify")
local Config = require("../config")
local Manageauth = require("../account/manageauth")
local View = require("./view")
local ui = require("../ui")

type Node = ui.Node
type Entry = Manageauth.Entry
type Invocation = Argv.Invocation
type TargetView = View.TargetView

local M = {}

-- Production, sandbox or unknown, from the account id when the CLI printed
-- one, else from a configured auth id. The list prints no account id for
-- production hosts, so those rows stay "unknown" unless configured.
function M.badge(e: Entry, cfg: Config.Config): TargetView
	if e.accountId then
		return View.fromClassify(Classify.account(e.accountId, cfg), e.accountId)
	end
	local c = Classify.authId(e.authId, cfg)
	if c then
		return View.fromClassify(c, "configured auth ID · " .. c.accountId)
	end
	return {
		text = "unknown",
		tone = "warning",
		title = "The CLI printed no account id; run `suitecloud account:manageauth --info " .. e.authId .. "`",
	}
end

local function badgeNode(e: Entry, cfg: Config.Config, key: string): Node
	local b = M.badge(e, cfg)
	return ui.badge(b.text, b.tone, { key = key, title = b.title, role = "tern-netsuite.account" })
end

local function cell(text: string?, class: string?): Node
	return ui.el("td", { text = text or "", class = class })
end

-- Lines the parser did not read, as View shows them, so Raw has nothing more.
local function otherNode(lines: { string }): Node?
	if #lines == 0 then
		return nil
	end
	local rows: { Node } = table.create(#lines)
	for i, l in lines do
		rows[i] = ui.text({ ui.span(l, "mono") }, { key = "u" .. i })
	end
	return ui.section({ ui.span("Other output", "strong") }, rows, { key = "unknown" })
end

local function withOther(node: Node, other: Node?): Node
	if other and node.c then
		table.insert(node.c, other)
	end
	return node
end

local function listNode(entries: { Entry }, cfg: Config.Config): Node
	local head: { Node } = {}
	for _, h in { "Account", "Auth ID", "Role", "Company", "Domain" } do
		table.insert(head, ui.el("th", { text = h }))
	end
	local rows: { Node } = table.create(#entries)
	for i, e in entries do
		rows[i] = ui.el("tr", { key = "r:" .. e.authId }, {
			ui.el("td", nil, { badgeNode(e, cfg, "b" .. i) }),
			cell(e.authId, "mono"),
			cell(e.role),
			cell(e.accountName),
			cell(e.domain or e.accountId, "muted"),
		})
	end
	local summary = #entries .. " auth ID" .. (if #entries == 1 then "" else "s")
	return ui.col({
		ui.text({ ui.span("suitecloud account:manageauth --list", "mono strong"), "  ", ui.span(summary, "muted") }),
		ui.el("table", { key = "auth", class = "tns-auth" }, {
			ui.el("thead", nil, { ui.el("tr", nil, head) }),
			ui.el("tbody", nil, rows),
		}),
	}, { key = "manageauth", role = "tern-netsuite.manageauth" })
end

local function infoNode(e: Entry, cfg: Config.Config): Node
	local items: { { { ui.SpanLike } } } = {}
	local function add(label: string, value: string?)
		if value then
			table.insert(items, { { label }, { value } })
		end
	end
	add("Account ID", e.accountId)
	add("Account name", e.accountName)
	add("Role", e.role)
	add("Domain", e.domain)
	add("Account type", e.kind)
	return ui.col({
		ui.row({
			badgeNode(e, cfg, "badge"),
			ui.text({ ui.span(e.authId, "mono strong") }),
		}, { key = "bar" }),
		ui.kv(items),
	}, { key = "manageauth", role = "tern-netsuite.manageauth" })
end

-- nil (raw) for anything but a parsed --list or --info result.
function M.render(inv: Invocation, lines: { string }, cfg: Config.Config): Node?
	if inv.command ~= "account:manageauth" or not Argv.renders(inv) then
		return nil
	end
	if inv.flags.list == true then
		local entries = Manageauth.parseList(lines)
		return if entries then withOther(listNode(entries, cfg), otherNode(Manageauth.unrecognizedList(lines))) else nil
	end
	if type(inv.flags.info) == "string" then
		local info = Manageauth.parseInfo(lines)
		return if info then withOther(infoNode(info, cfg), otherNode(Manageauth.unrecognizedInfo(lines))) else nil
	end
	return nil
end

return table.freeze(M)
