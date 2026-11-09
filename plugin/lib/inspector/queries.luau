--!strict
-- The SuiteQL the inspector runs. Values are always `?` parameters; the only
-- spliced identifiers are catalog tables, `customrecord_` script ids and
-- column names of the record row, each checked here (`identifier`).
--
-- Tables and columns used (SuiteQL, read-only):
--   <table>            SELECT * for the record (`transaction`, `customer`,
--                      `item`, `customrecord_x`...)
--   customrecordtype   internalid, scriptid, name: a custom record type's
--                      table and numeric id (UI URL rectype, system notes)
--   customfield        scriptid, name (the label), fieldvaluetyperecord (the
--                      record type a list/record field points at)
--   systemnote         date, name (who), role, context, type (the action:
--                      a static 1..4 that BUILTIN.DF refuses, named in
--                      record.luau), field (BUILTIN.DF gives its label),
--                      oldvalue, newvalue, recordid, recordtypeid
--   transactionline    transaction, linesequencenumber, mainline, item,
--                      quantity, netamount, memo, createdfrom (the
--                      transaction a line was created from; `transaction`
--                      has no createdfrom column in SuiteQL)
--   transaction        entity (records pointing back)

local Catalog = require("./catalog")

local M = {}

export type Query = { sql: string, params: { any }, max_rows: number }

M.MAX_LABEL_FIELDS = 100
M.MAX_NOTES = 200
M.MAX_LINES = 200
M.MAX_CHILDREN = 50
M.MAX_ENTITY_TRANSACTIONS = 25

-- Whether `name` may be spliced into SQL as a column or table name.
function M.identifier(name: string): boolean
	return #name <= 64 and string.find(name, "^[a-z][a-z0-9_]*$") ~= nil
end

local function num(id: string): number
	return tonumber(id) :: number
end

-- A custom record type by numeric internal id or by script id.
function M.customRecordType(rectype: number?, scriptid: string?): Query
	local cols = "SELECT internalid AS rectype, LOWER(scriptid) AS scriptid, name AS name FROM customrecordtype"
	if rectype then
		return { sql = cols .. " WHERE internalid = ?", params = { rectype }, max_rows = 1 }
	end
	return { sql = cols .. " WHERE LOWER(scriptid) = ?", params = { scriptid or "" }, max_rows = 1 }
end

-- Every column of the record, or nil when `kind`'s table is not safe.
function M.record(kind: Catalog.Kind, id: string): Query?
	if not M.identifier(kind.table) then
		return nil
	end
	return { sql = "SELECT * FROM " .. kind.table .. " WHERE id = ?", params = { num(id) }, max_rows = 1 }
end

local CUSTOM_PREFIXES = { "custbody", "custcol", "custentity", "custitem", "custrecord", "custevent" }

-- Whether `column` is a custom field (custbody_x, custentity_x, ...).
function M.isCustomField(column: string): boolean
	for _, p in CUSTOM_PREFIXES do
		if string.sub(column, 1, #p) == p and #column > #p then
			return true
		end
	end
	return false
end

-- Labels of custom field columns (at most MAX_LABEL_FIELDS, in order).
-- `refs` also asks which custom record type each field points at; the
-- plain form is the fallback when the account rejects that join.
function M.labels(columns: { string }, refs: boolean): Query?
	local fields: { string } = {}
	for _, c in columns do
		if M.isCustomField(c) and M.identifier(c) then
			table.insert(fields, c)
			if #fields >= M.MAX_LABEL_FIELDS then
				break
			end
		end
	end
	if #fields == 0 then
		return nil
	end
	local marks = string.rep("?, ", #fields - 1) .. "?"
	local sql = if refs
		then "SELECT LOWER(cf.scriptid) AS scriptid, cf.name AS label, LOWER(crt.scriptid) AS reftype"
			.. " FROM customfield cf LEFT JOIN customrecordtype crt ON crt.internalid = cf.fieldvaluetyperecord"
			.. " WHERE LOWER(cf.scriptid) IN ("
			.. marks
			.. ")"
		else "SELECT LOWER(scriptid) AS scriptid, name AS label FROM customfield WHERE LOWER(scriptid) IN ("
			.. marks
			.. ")"
	return { sql = sql, params = fields, max_rows = #fields }
end

-- Display names (BUILTIN.DF) of the record's reference `columns`.
function M.display(kind: Catalog.Kind, id: string, columns: { string }): Query?
	if not M.identifier(kind.table) then
		return nil
	end
	local parts: { string } = {}
	for _, c in columns do
		if M.identifier(c) then
			table.insert(parts, string.format("BUILTIN.DF(%s) AS %s", c, c))
		end
	end
	if #parts == 0 then
		return nil
	end
	return {
		sql = "SELECT " .. table.concat(parts, ", ") .. " FROM " .. kind.table .. " WHERE id = ?",
		params = { num(id) },
		max_rows = 1,
	}
end

-- The record's system notes, newest first; nil without note types.
function M.notes(id: string, types: { number }): Query?
	if #types == 0 then
		return nil
	end
	local params: { any } = { num(id) }
	for _, t in types do
		table.insert(params, t)
	end
	return {
		sql = "SELECT sn.id AS id, TO_CHAR(sn.date, 'YYYY-MM-DD HH24:MI:SS') AS noted,"
			.. " BUILTIN.DF(sn.name) AS who, BUILTIN.DF(sn.role) AS role, BUILTIN.DF(sn.context) AS context,"
			.. " sn.type AS action, sn.field AS field, BUILTIN.DF(sn.field) AS fieldlabel,"
			.. " sn.oldvalue AS oldvalue, sn.newvalue AS newvalue"
			.. " FROM systemnote sn WHERE sn.recordid = ? AND sn.recordtypeid IN ("
			.. string.rep("?, ", #types - 1)
			.. "?) ORDER BY sn.date DESC, sn.id DESC",
		params = params,
		max_rows = M.MAX_NOTES,
	}
end

-- A transaction's item and expense lines (not the main line).
function M.lines(id: string): Query
	return {
		sql = "SELECT tl.id AS line, tl.linesequencenumber AS seq, tl.item AS item, BUILTIN.DF(tl.item) AS itemname,"
			.. " tl.quantity AS quantity, tl.netamount AS amount, tl.memo AS memo"
			.. " FROM transactionline tl WHERE tl.transaction = ? AND tl.mainline = 'F'"
			.. " ORDER BY tl.linesequencenumber",
		params = { num(id) },
		max_rows = M.MAX_LINES,
	}
end

-- Transactions created from this one (fulfillments, invoices, ...): their
-- lines carry `createdfrom`.
function M.children(id: string): Query
	return {
		sql = "SELECT DISTINCT t.id AS id, t.type AS type, t.tranid AS tranid, BUILTIN.DF(t.status) AS status"
			.. " FROM transaction t JOIN transactionline tl ON tl.transaction = t.id"
			.. " WHERE tl.createdfrom = ? ORDER BY t.id",
		params = { num(id) },
		max_rows = M.MAX_CHILDREN,
	}
end

-- What a transaction was created from: its lines carry `createdfrom`.
function M.createdFrom(id: string): Query
	return {
		sql = "SELECT DISTINCT tl.createdfrom AS createdfrom, BUILTIN.DF(tl.createdfrom) AS name"
			.. " FROM transactionline tl WHERE tl.transaction = ? AND tl.createdfrom IS NOT NULL",
		params = { num(id) },
		max_rows = M.MAX_CHILDREN,
	}
end

-- An entity's newest transactions.
function M.entityTransactions(id: string): Query
	return {
		sql = "SELECT t.id AS id, t.type AS type, t.tranid AS tranid, BUILTIN.DF(t.status) AS status"
			.. " FROM transaction t WHERE t.entity = ? ORDER BY t.id DESC",
		params = { num(id) },
		max_rows = M.MAX_ENTITY_TRANSACTIONS,
	}
end

return M
