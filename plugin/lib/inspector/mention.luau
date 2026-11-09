--!strict
-- Finds a record that free text (an execution log title or detail) refers
-- to, so the log view can offer "Inspect": the first of
--   a NetSuite UI URL                        .../salesord.nl?id=123
--   a JSON-style type and id pair            "recordType":"salesorder", ... "id":123
--                                            (type / recordType / record_type with
--                                            id / recordId / internalid)
--   a `type:id` token of a catalog type      salesorder:123, customrecord_x:5
-- Unknown record types are never guessed.

local Catalog = require("./catalog")
local Ref = require("./ref")

local M = {}
export type Ref = Ref.Ref

M.MAX_SCAN = 20000

local function fromUrl(text: string): Ref.Ref?
	for url in string.gmatch(text, "[Hh][Tt][Tt][Pp][Ss]://[%w%.%-]+%.app%.netsuite%.com/[^%s\"'<>]+") do
		local r = Ref.parse(url)
		if r then
			return r
		end
	end
	return nil
end

local TYPE_KEYS = { "recordtype", "record_type", "type" }
local ID_KEYS = { "recordid", "record_id", "internalid", "id" }

local function jsonValue(lower: string, key: string): string?
	return string.match(lower, '"' .. key .. '"%s*:%s*"?([%w_]+)"?')
end

local function fromJson(text: string): Ref.Ref?
	local lower = string.lower(text)
	for _, tk in TYPE_KEYS do
		local name = jsonValue(lower, tk)
		local kind = if name then Catalog.find(name) else nil
		if kind then
			for _, ik in ID_KEYS do
				local id = jsonValue(lower, ik)
				if id and Ref.id(id) then
					return { kind = kind, id = id, rectype = nil, account = nil }
				end
			end
		end
	end
	return nil
end

local function fromToken(text: string): Ref.Ref?
	for name: string, raw: string in string.gmatch(text, "([%a][%w_]*):(%d+)") :: any do
		local kind = Catalog.find(name)
		local id = Ref.id(raw)
		if kind and id then
			return { kind = kind, id = id, rectype = nil, account = nil }
		end
	end
	return nil
end

-- The record the first of `texts` that mentions one refers to, or nil.
function M.find(texts: { string }): Ref.Ref?
	for _, finder in { fromUrl, fromJson, fromToken } do
		for _, t in texts do
			local text = if #t > M.MAX_SCAN then string.sub(t, 1, M.MAX_SCAN) else t
			local r = finder(text)
			if r then
				return r
			end
		end
	end
	return nil
end

return M
