--!strict
-- Turns SuiteQL rows into what the inspector shows: the record's fields
-- (with custom field labels), the records it points at, its system notes,
-- transaction lines and the transactions that point back at it. The REST
-- transport returns every value as a string (plus a `links` member); the
-- RESTlet returns typed values and JSON null; both read the same here.

local Catalog = require("./catalog")
local Queries = require("./queries")
local Ref = require("./ref")

local M = {}

export type Field = { column: string, value: string? }

-- Custom field metadata by column: the label and, for a field pointing at a
-- custom record, that type's script id.
export type Labels = { [string]: { label: string, reftype: string? } }

-- A record this one points at (or that points back at it).
export type Related = {
	key: string,
	-- What the relation is ("Entity", "Created from", "Line 3 item"...).
	label: string,
	-- Canonical record type to inspect it as.
	record: string,
	id: string,
	-- Display name, when known.
	name: string?,
}

export type Note = {
	id: string,
	noted: string,
	who: string?,
	role: string?,
	context: string?,
	action: string?,
	-- Field id (TRANDOC.KSTATUS) and its label (Document Status).
	field: string?,
	fieldLabel: string?,
	old: string?,
	new: string?,
}

export type Line = {
	seq: string,
	item: string?,
	itemName: string?,
	quantity: string?,
	amount: string?,
	memo: string?,
}

-- Text of a SuiteQL value; nil for null, missing and empty values.
function M.text(v: any, null: any?): string?
	if v == nil or (null ~= nil and v == null) then
		return nil
	end
	local tv = type(v)
	local s: string
	if tv == "string" then
		s = v
	elseif tv == "number" then
		s = if v % 1 == 0 and math.abs(v) < 1e15 then string.format("%d", v) else string.format("%.14g", v)
	elseif tv == "boolean" then
		s = if v then "T" else "F"
	else
		return nil
	end
	return if s == "" then nil else s
end

local function lowerKeys(row: any): { [string]: any }
	local out: { [string]: any } = {}
	if type(row) ~= "table" then
		return out
	end
	for k, v in row do
		if type(k) == "string" then
			out[string.lower(k)] = v
		end
	end
	return out
end

local isCustom = Queries.isCustomField

-- The record's fields: `id` first, then standard fields, then custom fields,
-- each alphabetically. REST's `links` member is not a field.
function M.fields(row: any, null: any?): { Field }
	local out: { Field } = {}
	for k, v in lowerKeys(row) do
		if k ~= "links" then
			table.insert(out, { column = k, value = M.text(v, null) })
		end
	end
	table.sort(out, function(a: Field, b: Field): boolean
		if (a.column == "id") ~= (b.column == "id") then
			return a.column == "id"
		end
		local ca, cb = isCustom(a.column), isCustom(b.column)
		if ca ~= cb then
			return cb
		end
		return a.column < b.column
	end)
	return out
end

function M.value(fields: { Field }, column: string): string?
	for _, f in fields do
		if f.column == column then
			return f.value
		end
	end
	return nil
end

function M.labels(rows: { any }?, null: any?): Labels
	local out: Labels = {}
	for _, r in (rows or {}) :: { any } do
		local row = lowerKeys(r)
		local id = M.text(row.scriptid, null)
		local label = M.text(row.label, null)
		if id and label then
			local reftype = M.text(row.reftype, null)
			out[string.lower(id)] = {
				label = label,
				reftype = if reftype and Catalog.isCustomRecord(string.lower(reftype))
					then string.lower(reftype)
					else nil,
			}
		end
	end
	return out
end

-- Display names by column from a BUILTIN.DF row.
function M.display(rows: { any }?, null: any?): { [string]: string }
	local out: { [string]: string } = {}
	local first = if rows then rows[1] else nil
	for k, v in lowerKeys(first) do
		local t = M.text(v, null)
		if t and k ~= "links" then
			out[k] = t
		end
	end
	return out
end

-- The more specific kind a record row shows (a `transaction` row's type
-- code, an `item` row's itemtype), else `kind`.
function M.refine(kind: Catalog.Kind, fields: { Field }): Catalog.Kind
	local code: string? = nil
	if kind.family == "transaction" then
		code = M.value(fields, "type")
	elseif kind.family == "item" then
		code = M.value(fields, "itemtype")
	end
	if code then
		return Catalog.fromCode(kind.family, code) or kind
	end
	return kind
end

local TITLE_COLUMNS = { "tranid", "entityid", "itemid", "companyname", "altname", "name", "fullname", "title" }

-- The record's human name (document number, entity id, item name...).
function M.title(fields: { Field }): string?
	for _, c in TITLE_COLUMNS do
		local v = M.value(fields, c)
		if v then
			return v
		end
	end
	return nil
end

-- Reference columns of the record (catalog columns of its family and
-- custom fields pointing at custom records) that hold a single id.
function M.references(kind: Catalog.Kind, fields: { Field }, labels: Labels): { Related }
	local out: { Related } = {}
	local seen: { [string]: boolean } = {}
	for _, ref in Catalog.refs(kind) do
		local v = M.value(fields, ref.column)
		local id = if v then Ref.id(v) else nil
		if id and not seen[ref.column] then
			seen[ref.column] = true
			table.insert(out, {
				key = "f:" .. ref.column,
				label = ref.label,
				record = if ref.record == "" then kind.record else ref.record,
				id = id,
				name = nil,
			})
		end
	end
	for _, f in fields do
		local meta = labels[f.column]
		local id = if f.value then Ref.id(f.value) else nil
		if meta and meta.reftype and id and not seen[f.column] then
			seen[f.column] = true
			table.insert(out, {
				key = "f:" .. f.column,
				label = meta.label,
				record = meta.reftype,
				id = id,
				name = nil,
			})
		end
	end
	return out
end

-- Columns whose display names to ask for (BUILTIN.DF).
function M.displayColumns(refs: { Related }): { string }
	local out: { string } = {}
	for _, r in refs do
		local column = string.match(r.key, "^f:(.+)$")
		if column then
			table.insert(out, column)
		end
	end
	return out
end

-- `refs` with display names filled in.
function M.named(refs: { Related }, names: { [string]: string }): { Related }
	local out: { Related } = table.create(#refs)
	for i, r in refs do
		local column = string.match(r.key, "^f:(.+)$")
		local copy = table.clone(r)
		if column and names[column] and names[column] ~= r.id then
			copy.name = names[column]
		end
		out[i] = copy
	end
	return out
end

-- `systemnote.type` is a static field BUILTIN.DF refuses; its values as
-- the UI names them.
local NOTE_TYPES: { [string]: string } = { ["1"] = "Create", ["2"] = "Set", ["3"] = "Delete", ["4"] = "Change" }

function M.notes(rows: { any }?, null: any?): { Note }
	local out: { Note } = {}
	for i, r in (rows or {}) :: { any } do
		local row = lowerKeys(r)
		local action = M.text(row.action, null)
		local field = M.text(row.field, null)
		local fieldLabel = M.text(row.fieldlabel, null)
		table.insert(out, {
			id = M.text(row.id, null) or tostring(i),
			noted = M.text(row.noted, null) or "",
			who = M.text(row.who, null),
			role = M.text(row.role, null),
			context = M.text(row.context, null),
			action = if action then NOTE_TYPES[action] or action else nil,
			field = field,
			fieldLabel = if fieldLabel ~= field then fieldLabel else nil,
			old = M.text(row.oldvalue, null),
			new = M.text(row.newvalue, null),
		})
	end
	return out
end

function M.lines(rows: { any }?, null: any?): { Line }
	local out: { Line } = {}
	for i, r in (rows or {}) :: { any } do
		local row = lowerKeys(r)
		table.insert(out, {
			seq = M.text(row.seq, null) or M.text(row.line, null) or tostring(i),
			item = M.text(row.item, null),
			itemName = M.text(row.itemname, null),
			quantity = M.text(row.quantity, null),
			amount = M.text(row.amount, null),
			memo = M.text(row.memo, null),
		})
	end
	return out
end

-- Item links of transaction lines (one per distinct item).
function M.lineItems(lines: { Line }): { Related }
	local out: { Related } = {}
	local seen: { [string]: boolean } = {}
	for _, l in lines do
		local id = if l.item then Ref.id(l.item) else nil
		if id and not seen[id] then
			seen[id] = true
			table.insert(out, {
				key = "item:" .. id,
				label = "Line item",
				record = "item",
				id = id,
				name = l.itemName,
			})
		end
	end
	return out
end

-- Transactions from a `transaction` query (`id`, `type`, `tranid`,
-- `status`), labelled `label`.
function M.transactions(rows: { any }?, label: string, null: any?): { Related }
	local out: { Related } = {}
	for _, r in (rows or {}) :: { any } do
		local row = lowerKeys(r)
		local id = Ref.id(M.text(row.id, null) or "")
		if id then
			local code = M.text(row.type, null)
			local kind = if code then Catalog.fromCode("transaction", code) else nil
			local name = M.text(row.tranid, null)
			local status = M.text(row.status, null)
			local parts: { string } = { if kind then kind.label else (code or "Transaction") }
			if name then
				table.insert(parts, name)
			end
			if status then
				table.insert(parts, "(" .. status .. ")")
			end
			table.insert(out, {
				key = label .. ":" .. id,
				label = label,
				record = if kind then kind.record else "transaction",
				id = id,
				name = table.concat(parts, " "),
			})
		end
	end
	return out
end

return M
