--!strict
-- What the user asks to inspect, from text they type or paste:
--
--   https://<account>.app.netsuite.com/app/accounting/transactions/salesord.nl?id=123
--   https://<account>.app.netsuite.com/app/common/custom/custrecordentry.nl?rectype=12&id=5
--   salesorder:123   customer:42   transaction:7   customrecord_acme_box:5   so:123
--
-- A bare internal id (`123`) needs a type the caller already knows (a log
-- row, a console column): `parse(text, kind)`. Other parameters of a UI URL
-- (`e=T`, `whence=`) are ignored; the URL's account selects the connection.

local Catalog = require("./catalog")

local M = {}

M.MAX_TEXT = 2048

export type Ref = {
	-- nil only for a custom record URL, which names its type by `rectype`.
	kind: Catalog.Kind?,
	id: string,
	-- A custom record type's numeric internal id.
	rectype: number?,
	-- Upper-case account id of a pasted UI URL.
	account: string?,
}

-- The canonical internal id, or nil.
function M.id(v: string): string?
	if #v <= 12 and string.find(v, "^[1-9]%d*$") then
		return v
	end
	return nil
end

local function rectype(v: string?): number?
	if v == nil or #v > 9 or not string.find(v, "^[1-9]%d*$") then
		return nil
	end
	return tonumber(v)
end

local function fromUrl(text: string): (Ref?, string?)
	local host, path, query = string.match(text, "^[Hh][Tt][Tt][Pp][Ss]://([^/?#]+)(/[^?#]*)%??([^#]*)")
	if host == nil or path == nil then
		return nil, "not a NetSuite UI URL (https://<account>.app.netsuite.com/app/...)"
	end
	local account = Catalog.accountOfHost(host)
	if account == nil then
		return nil, string.format("%q is not a NetSuite UI host (<account>.app.netsuite.com)", host)
	end
	local params: { [string]: string } = {}
	for pair in string.gmatch(query or "", "[^&]+") do
		local k, v = string.match(pair, "^([^=]+)=(.*)$")
		if k and v then
			local key = string.lower(k)
			if params[key] == nil then
				params[key] = v
			end
		end
	end
	local id = M.id(params.id or "")
	if id == nil then
		return nil, "the URL has no record id (id=<number>)"
	end
	if string.lower(path) == Catalog.CUSTOM_RECORD_UI then
		local rt = rectype(params.rectype)
		if rt == nil then
			return nil, "a custom record URL needs rectype=<number>"
		end
		return { kind = nil, id = id, rectype = rt, account = account }, nil
	end
	local kind = Catalog.fromPath(path)
	if kind == nil then
		return nil, string.format("unknown NetSuite page %q: use type:id instead", path)
	end
	return { kind = kind, id = id, rectype = nil, account = account }, nil
end

-- The reference `text` names, or nil and why. `kind` types a bare id.
function M.parse(text: string, kind: Catalog.Kind?): (Ref?, string?)
	if #text > M.MAX_TEXT then
		return nil, "the text is too long"
	end
	local t = string.match(text, "^%s*(.-)%s*$") :: string
	if t == "" then
		return nil, "paste a NetSuite record URL or type type:id (e.g. salesorder:123)"
	end
	if string.find(t, "%c") then
		return nil, "the text has a control character"
	end
	if string.find(t, "^[Hh][Tt][Tt][Pp][Ss]?://") then
		return fromUrl(t)
	end
	local name, rawId = string.match(t, "^([%w_]+)%s*:%s*(%S+)$")
	if name and rawId then
		local id = M.id(rawId)
		if id == nil then
			return nil, string.format("%q is not an internal id (a positive number)", rawId)
		end
		local k = Catalog.find(name)
		if k == nil then
			return nil, string.format("unknown record type %q (e.g. salesorder, customer, item, customrecord_x)", name)
		end
		return { kind = k, id = id, rectype = nil, account = nil }, nil
	end
	local id = M.id(t)
	if id then
		if kind == nil then
			return nil, "add the record type: type:" .. id .. " (e.g. salesorder:" .. id .. ")"
		end
		return { kind = kind, id = id, rectype = nil, account = nil }, nil
	end
	return nil, "not a record: paste a NetSuite record URL or type type:id (e.g. salesorder:123)"
end

-- `type:id` text for `ref`; a custom record URL's ref (type not known yet)
-- gives its URL back when it names an account.
function M.text(ref: Ref): string
	if ref.kind then
		return ref.kind.record .. ":" .. ref.id
	end
	local host = if ref.account then Catalog.host(ref.account) else nil
	local path = string.format("%s?rectype=%d&id=%s", Catalog.CUSTOM_RECORD_UI, ref.rectype or 0, ref.id)
	return if host then "https://" .. host .. path else path
end

return M
