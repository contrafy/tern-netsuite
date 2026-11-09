--!strict
-- The record types the inspector knows: how a NetSuite UI URL, a record type
-- name or a SuiteQL table maps to the table to read, the UI page that shows
-- the record, the `systemnote.recordtypeid` values of its notes and the
-- columns that point at other records. Pure data plus lookups; extend the
-- tables below to support more types.
--
-- Families:
--   transaction   SuiteQL `transaction` (one table for every type; `type`
--                 holds the code, e.g. SalesOrd); system notes use
--                 recordtypeid -30
--   entity        its own table per type (customer, vendor, ...) and the
--                 generic `entity` table
--   item          SuiteQL `item` (`itemtype` holds the code, e.g. InvtPart)
--   list          other standard records (subsidiary, department, ...)
--   customrecord  `customrecord_<x>` tables; the UI page and system notes
--                 need the record type's numeric internal id (`rectype`),
--                 which `customrecordtype` gives
--
-- Limits: UI pages exist for the types listed; other transactions open
-- through `transaction.nl`, other entities through `entity.nl` and items
-- through `item.nl`, which NetSuite redirects to the right form. Types not
-- listed here (and not custom records) cannot be opened.

local M = {}

export type Family = "transaction" | "entity" | "item" | "list" | "customrecord"

export type Kind = {
	-- Canonical record type id (SuiteScript `record.Type` value, lower case).
	record: string,
	label: string,
	family: Family,
	-- SuiteQL table holding the record.
	table: string,
	-- UI page path (`?id=<id>` is appended); nil for custom records.
	ui: string?,
	-- `transaction.type` / `item.itemtype` code, when the family has one.
	code: string?,
	-- `systemnote.recordtypeid` values of the type's notes.
	notes: { number },
	-- Custom records: the type's numeric internal id, once known.
	rectype: number?,
}

-- A column of a family's records that holds another record's internal id.
export type RefColumn = { column: string, record: string, label: string }

M.HOST_SUFFIX = ".app.netsuite.com"
M.CUSTOM_RECORD_UI = "/app/common/custom/custrecordentry.nl"
M.TRANSACTION_NOTES = -30

local TRANSACTION_UI = "/app/accounting/transactions/"
local ENTITY_UI = "/app/common/entity/"
local ITEM_UI = "/app/common/item/item.nl"

-- record, label, UI page (under TRANSACTION_UI), `transaction.type` code.
local TRANSACTIONS: { { string } } = {
	{ "salesorder", "Sales order", "salesord", "SalesOrd" },
	{ "invoice", "Invoice", "custinvc", "CustInvc" },
	{ "cashsale", "Cash sale", "cashsale", "CashSale" },
	{ "creditmemo", "Credit memo", "custcred", "CustCred" },
	{ "customerpayment", "Customer payment", "custpymt", "CustPymt" },
	{ "customerdeposit", "Customer deposit", "custdep", "CustDep" },
	{ "customerrefund", "Customer refund", "custrfnd", "CustRfnd" },
	{ "cashrefund", "Cash refund", "cashrfnd", "CashRfnd" },
	{ "returnauthorization", "Return authorization", "rtnauth", "RtnAuth" },
	{ "estimate", "Estimate", "estimate", "Estimate" },
	{ "opportunity", "Opportunity", "opprtnty", "Opprtnty" },
	{ "purchaseorder", "Purchase order", "purchord", "PurchOrd" },
	{ "vendorbill", "Vendor bill", "vendbill", "VendBill" },
	{ "vendorcredit", "Vendor credit", "vendcred", "VendCred" },
	{ "vendorpayment", "Vendor payment", "vendpymt", "VendPymt" },
	{ "vendorreturnauthorization", "Vendor return authorization", "vendauth", "VendAuth" },
	{ "itemfulfillment", "Item fulfillment", "itemship", "ItemShip" },
	{ "itemreceipt", "Item receipt", "itemrcpt", "ItemRcpt" },
	{ "transferorder", "Transfer order", "trnfrord", "TrnfrOrd" },
	{ "inventoryadjustment", "Inventory adjustment", "invadjst", "InvAdjst" },
	{ "inventorytransfer", "Inventory transfer", "invtrnfr", "InvTrnfr" },
	{ "workorder", "Work order", "workord", "WorkOrd" },
	{ "journalentry", "Journal entry", "journal", "Journal" },
	{ "check", "Check", "check", "Check" },
	{ "deposit", "Deposit", "deposit", "Deposit" },
	{ "expensereport", "Expense report", "exprept", "ExpRept" },
	-- Any transaction: NetSuite redirects to the type's own form.
	{ "transaction", "Transaction", "transaction", "" },
}

-- record, label, table, UI page (under ENTITY_UI), system note type, the
-- generic `entity` row's `type` code.
local ENTITIES: { { any } } = {
	{ "customer", "Customer", "customer", "custjob", -2, "CustJob" },
	{ "job", "Project", "job", "custjob", -7, "Job" },
	{ "vendor", "Vendor", "vendor", "vendor", -3, "Vendor" },
	{ "employee", "Employee", "employee", "employee", -4, "Employee" },
	{ "partner", "Partner", "partner", "partner", -5, "Partner" },
	{ "contact", "Contact", "contact", "contact", -6, "Contact" },
	{ "entity", "Entity", "entity", "entity", 0, "" },
}
-- Every entity's notes may also be filed under the generic entity type.
local ENTITY_NOTES = -9
local ITEM_NOTES = -10

-- record, label, `item.itemtype` code.
local ITEMS: { { string } } = {
	{ "inventoryitem", "Inventory item", "InvtPart" },
	{ "noninventoryitem", "Non-inventory item", "NonInvtPart" },
	{ "serviceitem", "Service item", "Service" },
	{ "otherchargeitem", "Other charge item", "OthCharge" },
	{ "kititem", "Kit item", "Kit" },
	{ "assemblyitem", "Assembly item", "Assembly" },
	{ "itemgroup", "Item group", "Group" },
	{ "discountitem", "Discount item", "Discount" },
	{ "markupitem", "Markup item", "Markup" },
	{ "paymentitem", "Payment item", "Payment" },
	{ "subtotalitem", "Subtotal item", "Subtotal" },
	{ "descriptionitem", "Description item", "Description" },
	{ "giftcertificateitem", "Gift certificate item", "GiftCert" },
	{ "item", "Item", "" },
}

-- record (= SuiteQL table), label, UI page, system note type.
local LISTS: { { any } } = {
	{ "subsidiary", "Subsidiary", "/app/common/otherlists/subsidiarytype.nl", -117 },
	{ "department", "Department", "/app/common/otherlists/departmenttype.nl", -102 },
	{ "location", "Location", "/app/common/otherlists/locationtype.nl", -103 },
	{ "classification", "Class", "/app/common/otherlists/classtype.nl", -101 },
	{ "account", "Account", "/app/accounting/account/account.nl", -112 },
}

-- Other spellings people paste (`type:id`) for a record type.
local ALIASES: { [string]: string } = {
	so = "salesorder",
	po = "purchaseorder",
	inv = "invoice",
	bill = "vendorbill",
	journal = "journalentry",
	["class"] = "classification",
	project = "job",
	salesord = "salesorder",
	purchord = "purchaseorder",
	custinvc = "invoice",
}

-- Columns that point at other records, per family (custom fields that
-- point at custom records are found through the field metadata instead;
-- what a transaction was created from comes from its lines, as SuiteQL's
-- `transaction` has no createdfrom column).
local REFS: { [string]: { RefColumn } } = {
	transaction = {
		{ column = "entity", record = "entity", label = "Entity" },
		{ column = "opportunity", record = "transaction", label = "Opportunity" },
		{ column = "intercotransaction", record = "transaction", label = "Intercompany transaction" },
		{ column = "employee", record = "employee", label = "Employee" },
		{ column = "partner", record = "partner", label = "Partner" },
		{ column = "subsidiary", record = "subsidiary", label = "Subsidiary" },
		{ column = "department", record = "department", label = "Department" },
		{ column = "location", record = "location", label = "Location" },
		{ column = "class", record = "classification", label = "Class" },
	},
	entity = {
		{ column = "parent", record = "entity", label = "Parent" },
		{ column = "company", record = "entity", label = "Company" },
		{ column = "supervisor", record = "employee", label = "Supervisor" },
		{ column = "salesrep", record = "employee", label = "Sales rep" },
		{ column = "subsidiary", record = "subsidiary", label = "Subsidiary" },
		{ column = "department", record = "department", label = "Department" },
		{ column = "location", record = "location", label = "Location" },
		{ column = "class", record = "classification", label = "Class" },
	},
	item = {
		{ column = "parent", record = "item", label = "Parent" },
		{ column = "department", record = "department", label = "Department" },
		{ column = "location", record = "location", label = "Location" },
		{ column = "class", record = "classification", label = "Class" },
	},
	list = {
		{ column = "parent", record = "", label = "Parent" },
	},
	customrecord = {
		-- `record = ""`: the same type as the record itself.
		{ column = "parent", record = "", label = "Parent" },
		{ column = "owner", record = "employee", label = "Owner" },
	},
}

local byRecord: { [string]: Kind } = {}
local byPath: { [string]: Kind } = {}
local byTable: { [string]: Kind } = {}
local byCode: { [string]: { [string]: Kind } } = { transaction = {}, item = {}, entity = {} }

local function add(k: Kind)
	table.freeze(k.notes)
	table.freeze(k)
	byRecord[k.record] = k
	-- Items share one page: it maps to the generic `item` kind. Projects
	-- share the customer page (custjob.nl): it maps to customer, added first.
	if k.ui and (byPath[k.ui] == nil or (k.family == "item" and k.code == nil)) then
		byPath[k.ui] = k
	end
	if byTable[k.table] == nil or k.table == k.record then
		byTable[k.table] = k
	end
	if k.code and k.code ~= "" and byCode[k.family] then
		byCode[k.family][string.lower(k.code)] = k
	end
end

for _, t in TRANSACTIONS do
	add({
		record = t[1],
		label = t[2],
		family = "transaction",
		table = "transaction",
		ui = TRANSACTION_UI .. t[3] .. ".nl",
		code = if t[4] == "" then nil else t[4],
		notes = { M.TRANSACTION_NOTES },
	})
end
for _, e in ENTITIES do
	local note = e[5] :: number
	add({
		record = e[1] :: string,
		label = e[2] :: string,
		family = "entity",
		table = e[3] :: string,
		ui = ENTITY_UI .. (e[4] :: string) .. ".nl",
		code = if e[6] == "" then nil else e[6] :: string,
		notes = if note == 0 then { ENTITY_NOTES } else { note, ENTITY_NOTES },
	})
end
for _, i in ITEMS do
	add({
		record = i[1],
		label = i[2],
		family = "item",
		table = "item",
		ui = ITEM_UI,
		code = if i[3] == "" then nil else i[3],
		notes = { ITEM_NOTES },
	})
end
for _, l in LISTS do
	add({
		record = l[1] :: string,
		label = l[2] :: string,
		family = "list",
		table = l[1] :: string,
		ui = l[3] :: string,
		code = nil,
		notes = { l[4] :: number },
	})
end

-- Whether `name` is a custom record type script id (also its table name).
function M.isCustomRecord(name: string): boolean
	return #name <= 100 and string.find(name, "^customrecord[a-z0-9_]+$") ~= nil
end

-- The kind of a custom record type `scriptid` (lower case).
function M.customRecord(scriptid: string, label: string?, rectype: number?): Kind
	return {
		record = scriptid,
		label = label or scriptid,
		family = "customrecord",
		table = scriptid,
		ui = nil,
		code = nil,
		notes = if rectype then { rectype } else {},
		rectype = rectype,
	}
end

-- The kind a record type name, alias or SuiteQL table names, or nil.
function M.find(name: string): Kind?
	local n = string.lower(name)
	n = ALIASES[n] or n
	local k = byRecord[n] or byTable[n]
	if k then
		return k
	end
	if M.isCustomRecord(n) then
		return M.customRecord(n)
	end
	return nil
end

-- The kind a UI page path shows (`/app/.../salesord.nl`), or nil.
function M.fromPath(path: string): Kind?
	return byPath[string.lower(path)]
end

-- The specific kind of a `transaction.type` / `item.itemtype` code, or nil.
function M.fromCode(family: Family, code: string): Kind?
	local t = byCode[family]
	return if t then t[string.lower(code)] else nil
end

-- The kind of the record type `record` (canonical id only), or nil.
function M.get(record: string): Kind?
	return byRecord[record]
end

-- Reference columns of `kind`'s family.
function M.refs(kind: Kind): { RefColumn }
	return REFS[kind.family] or {}
end

-- Kinds with no single REST record type: generic ones, and items REST
-- splits into sale / purchase / resale types (noninventorysaleitem, ...).
local NO_REST: { [string]: boolean } = {
	transaction = true,
	entity = true,
	item = true,
	noninventoryitem = true,
	otherchargeitem = true,
	serviceitem = true,
}

-- The REST record type whose metadata catalog entry titles `kind`'s
-- standard fields (lib/ns/metadata.luau), or nil when there is none. REST
-- record types are the SuiteScript record types; custom record types are
-- their script ids.
function M.restType(kind: Kind): string?
	if NO_REST[kind.record] then
		return nil
	end
	return kind.record
end

-- The UI host of `accountId` (`1234567_SB1` -> `1234567-sb1.app.netsuite.com`),
-- or nil for an id that cannot be a host name.
function M.host(accountId: string): string?
	if not string.find(accountId, "^[%w][%w_%-]*$") or #accountId > 64 then
		return nil
	end
	return (string.gsub(string.lower(accountId), "_", "-")) .. M.HOST_SUFFIX
end

-- The account id a UI host names (`1234567-sb1.app.netsuite.com` ->
-- `1234567_SB1`), or nil for other hosts.
function M.accountOfHost(host: string): string?
	local h = string.lower(host)
	local acct = string.match(h, "^([%w%-]+)%.app%.netsuite%.com$")
	if acct == nil then
		return nil
	end
	return string.upper((string.gsub(acct, "%-", "_")))
end

-- The record's page in the NetSuite UI, or nil and why not.
function M.uiUrl(kind: Kind, id: string, accountId: string): (string?, string?)
	local host = M.host(accountId)
	if host == nil then
		return nil, string.format("%q is not a NetSuite account id", accountId)
	end
	if kind.family == "customrecord" then
		if kind.rectype == nil then
			return nil, "the custom record type's internal id is not known yet"
		end
		return string.format("https://%s%s?rectype=%d&id=%s", host, M.CUSTOM_RECORD_UI, kind.rectype, id), nil
	end
	if kind.ui == nil then
		return nil, "no NetSuite page is known for " .. kind.label
	end
	return string.format("https://%s%s?id=%s", host, kind.ui, id), nil
end

return M
