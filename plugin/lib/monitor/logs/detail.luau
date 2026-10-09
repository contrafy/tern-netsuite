--!strict
-- Log details that are JSON objects or arrays (the `namespace:event` title
-- convention logs `JSON.stringify(payload)` as the detail) become a plain
-- disclosure tree; anything else stays raw text. NetSuite cuts details at
-- 3999 characters, so truncated JSON is common and simply stays raw.

local ui = require("../../ui")

type TreeNode = ui.TreeNode
type Span = ui.Span

local M = {}

-- Larger details are never decoded (a detail is at most 3999 characters in
-- NetSuite; this guards against anything else feeding the block).
M.MAX_BYTES = 65536
M.MAX_NODES = 500
M.MAX_DEPTH = 12
M.MAX_STRING = 200
-- Trees of at most this many nodes start with their top level expanded.
M.OPEN_NODES = 12

export type Parsed = {
	json: boolean,
	tree: { TreeNode }?,
	nodes: number,
	truncated: boolean,
}

local NOT_JSON: Parsed = table.freeze({ json = false, tree = nil, nodes = 0, truncated = false })

local function clip(s: string, max: number): string
	if #s <= max then
		return s
	end
	local n = utf8.len(s)
	if n == nil then
		return string.sub(s, 1, max - 1) .. "…"
	elseif n <= max then
		return s
	end
	return string.sub(s, 1, (utf8.offset(s, max) :: number) - 1) .. "…"
end

-- `detail` on one line, whitespace collapsed, at most `max` characters.
function M.preview(detail: string, max: number): string
	local flat = string.gsub(string.gsub(detail, "%s+", " "), "^ ", "")
	flat = string.gsub(flat, " $", "")
	return clip(flat, max)
end

type Kind = "array" | "object" | "empty" | "scalar"

local function kindOf(v: any): Kind
	if type(v) ~= "table" then
		return "scalar"
	end
	if next(v) == nil then
		return "empty"
	end
	local n = #v
	if n > 0 then
		local count = 0
		for _ in v do
			count += 1
		end
		if count == n then
			return "array"
		end
	end
	return "object"
end

local function scalar(v: any, null: any): Span
	if v == null then
		return ui.span("null", "muted")
	elseif type(v) == "string" then
		return ui.span('"' .. clip(v, M.MAX_STRING) .. '"', "success")
	elseif type(v) == "number" then
		return ui.span(string.format("%.14g", v), "accent")
	elseif type(v) == "boolean" then
		return ui.span(if v then "true" else "false", "accent")
	end
	return ui.span(tostring(v), "muted")
end

type Ctx = { nodes: number, truncated: boolean, null: any }

local build: (ctx: Ctx, v: any, depth: number) -> { TreeNode }

local function node(ctx: Ctx, head: { Span }, v: any, depth: number): TreeNode
	ctx.nodes += 1
	local id = "n" .. ctx.nodes
	if v == ctx.null then
		table.insert(head, scalar(v, ctx.null))
		return { id = id, label = head }
	end
	local kind = kindOf(v)
	if kind == "scalar" then
		table.insert(head, scalar(v, ctx.null))
		return { id = id, label = head }
	elseif kind == "empty" then
		table.insert(head, ui.span("(empty)", "muted"))
		return { id = id, label = head }
	end
	local count = 0
	for _ in v do
		count += 1
	end
	table.insert(head, ui.span(if kind == "array" then "[" .. count .. "]" else "{" .. count .. "}", "muted"))
	if depth >= M.MAX_DEPTH then
		ctx.truncated = true
		table.insert(head, ui.span(" …", "muted"))
		return { id = id, label = head }
	end
	return { id = id, label = head, children = build(ctx, v, depth + 1) }
end

function build(ctx: Ctx, v: any, depth: number): { TreeNode }
	local out: { TreeNode } = {}
	local entries: { { label: { Span }, value: any } } = {}
	if kindOf(v) == "array" then
		for i, item in v do
			table.insert(entries, { label = { ui.span("[" .. i .. "] ", "muted") }, value = item })
		end
	else
		local keys: { string } = {}
		for k in v do
			table.insert(keys, tostring(k))
		end
		table.sort(keys)
		for _, k in keys do
			table.insert(entries, { label = { ui.span(k, "strong"), ui.span(": ") }, value = v[k] })
		end
	end
	for i, e in entries do
		if ctx.nodes >= M.MAX_NODES then
			ctx.truncated = true
			ctx.nodes += 1
			table.insert(
				out,
				{ id = "n" .. ctx.nodes, label = { ui.span("… " .. (#entries - i + 1) .. " more", "muted") } }
			)
			break
		end
		local head = e.label
		local k = kindOf(e.value)
		if (k == "array" or k == "object") and e.value ~= ctx.null and string.sub(head[#head].t, -2) == ": " then
			-- `key {3}` / `key [2]` rather than `key: {3}`.
			head[#head] = ui.span(" ")
		end
		table.insert(out, node(ctx, head, e.value, depth))
	end
	return out
end

-- The tree of a JSON object or array `detail`; `json` is false (and `tree`
-- nil) for anything else, including invalid or oversized JSON. Never raises.
function M.parse(detail: string, decode: (string) -> any, null: any): Parsed
	if #detail > M.MAX_BYTES or not string.find(detail, "^%s*[%[{]") then
		return NOT_JSON
	end
	local ok, value = pcall(decode, detail)
	if not ok or type(value) ~= "table" or value == null then
		return NOT_JSON
	end
	local ctx: Ctx = { nodes = 0, truncated = false, null = null }
	local okBuild, tree = pcall(build, ctx, value, 1)
	if not okBuild then
		return NOT_JSON
	end
	-- The dock grows with its content and pushes the rows out of view, so
	-- only a small tree starts expanded.
	if ctx.nodes <= M.OPEN_NODES then
		for _, n in tree do
			if n.children then
				n.open = true
			end
		end
	end
	return { json = true, tree = tree, nodes = ctx.nodes, truncated = ctx.truncated }
end

return M
