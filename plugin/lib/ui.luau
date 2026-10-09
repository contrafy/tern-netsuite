--!strict
-- Plain-table equivalents of the `tern.ui` builders used by tern-kube. Tern
-- 0.6.2 accepts `{k, p, c}` tables as nodes (`tern.ui.node(k, p, c)` encodes
-- to the same JSON), and building them in Luau is ~50x cheaper than calling
-- the builders, which matters for 1000-row views.

export type Span = { t: string, s: string?, href: string? }
export type Node = { k: string, p: { [string]: any }?, c: { Node }? }
export type SpanLike = Span | string
export type TreeNode = { id: string, label: { Span }, open: boolean?, children: { TreeNode }? }

local M = {}

function M.span(t: string, s: string?): Span
	if s == nil or s == "" then
		return { t = t }
	end
	return { t = t, s = s }
end

function M.spans(list: { SpanLike }): { Span }
	local out: { Span } = table.create(#list)
	for i, s in list do
		out[i] = if type(s) == "string" then { t = s } else s
	end
	return out
end

function M.text(list: { SpanLike }, props: { [string]: any }?): Node
	local p: { [string]: any } = { spans = M.spans(list) }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "text", p = p }
end

function M.el(tag: string, props: { [string]: any }?, children: { Node }?): Node
	local p: { [string]: any } = { tag = tag }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "el", p = p, c = children }
end

function M.badge(text: string, tone: string, props: { [string]: any }?): Node
	local p: { [string]: any } = { text = text, tone = tone }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "badge", p = p }
end

function M.col(children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { gap = "sm" }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "col", p = p, c = children }
end

function M.row(children: { Node }, props: { [string]: any }?): Node
	local p: { [string]: any } = { gap = "sm" }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return { k = "row", p = p, c = children }
end

function M.kv(items: { { { SpanLike } } }): Node
	local out = table.create(#items)
	for i, pair in items do
		out[i] = { k = M.spans(pair[1]), v = M.spans(pair[2]) }
	end
	return { k = "kv", p = { items = out } }
end

local function withProps(p: { [string]: any }, props: { [string]: any }?): { [string]: any }
	if props then
		for k, v in props do
			p[k] = v
		end
	end
	return p
end

-- Prop names follow the SDK's own encoders (tern-sdk python ui/_kinds.py).
function M.card(head: { SpanLike }, children: { Node }, props: { [string]: any }?): Node
	return { k = "card", p = withProps({ head = M.spans(head) }, props), c = children }
end

function M.section(head: { SpanLike }, children: { Node }, props: { [string]: any }?): Node
	return { k = "section", p = withProps({ head = M.spans(head) }, props), c = children }
end

function M.code(text: string, lang: string?, start: number?, props: { [string]: any }?): Node
	return { k = "code", p = withProps({ text = text, lang = lang, start = start }, props) }
end

function M.tree(nodes: { TreeNode }, props: { [string]: any }?): Node
	return { k = "tree", p = withProps({ nodes = nodes }, props) }
end

function M.lines(children: { Node }, props: { [string]: any }?): Node
	return { k = "lines", p = withProps({}, props), c = children }
end

function M.rule(label: { SpanLike }?, props: { [string]: any }?): Node
	return { k = "rule", p = withProps(if label then { label = M.spans(label) } else {}, props) }
end

function M.muted(text: string, props: { [string]: any }?): Node
	return M.text({ M.span(text, "muted") }, props)
end

-- Role of the row list of a block (plugin/tern-netsuite.css): it fills the
-- main region below the header and scrolls itself, and Tern scrolls it to
-- the selected row. Works whatever size Tern reports (lib/pane.luau).
M.SCROLL_ROLE = "tern-netsuite.scroll"

-- The rows of a block: `key` names the list, a direct child of the main
-- region's root; `selected` is the key of the selected child (nil: none);
-- `lines` caps its height where the style sheet does not apply.
function M.scroll(key: string, children: { Node }, selected: string?, lines: number): Node
	return {
		k = "list",
		p = {
			key = key,
			role = M.SCROLL_ROLE,
			gap = "none",
			-- Tern matches `selected` against node ids: region.list.child.
			selected = if selected then "main." .. key .. "." .. selected else nil,
			-- Tern keeps the selected row in view only with `max`.
			max = { lines = lines },
		},
		c = children,
	}
end

-- Same output as `tern.ui.overflow(hidden)`.
function M.overflow(hidden: number): Node
	return M.muted("… " .. hidden .. " more (Raw shows everything)")
end

return M
