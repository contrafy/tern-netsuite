--!strict
-- Which secrets a connection needs and how they are named. Values live only
-- in tern.secrets (the system keychain) under `<connection-id>.<field>`;
-- this module validates them and never renders them.

local Config = require("../config")

local M = {}

export type Field = { id: string, label: string, multiline: boolean }

M.FIELDS = {
	tba = {
		{ id = "consumer_key", label = "Consumer key", multiline = false },
		{ id = "consumer_secret", label = "Consumer secret", multiline = false },
		{ id = "token_id", label = "Token ID", multiline = false },
		{ id = "token_secret", label = "Token secret", multiline = false },
	},
	oauth2_m2m = {
		{ id = "client_id", label = "Client ID", multiline = false },
		{ id = "certificate_id", label = "Certificate ID", multiline = false },
		{ id = "private_key", label = "Private key (PEM, paste)", multiline = true },
	},
} :: { [Config.Auth]: { Field } }

-- tern.secrets names match [a-z0-9][a-z0-9._-]{0,63}.
function M.secretName(connectionId: string, field: string): string?
	local name = connectionId .. "." .. field
	if string.find(name, "^[a-z0-9][a-z0-9%._%-]*$") == nil or #name > 64 then
		return nil
	end
	return name
end

-- Why credentials cannot be stored for `connectionId`, or nil.
function M.unstorable(connectionId: string, auth: Config.Auth): string?
	for _, f in M.FIELDS[auth] do
		if M.secretName(connectionId, f.id) == nil then
			return string.format(
				"connection id %q cannot name a keychain entry: use lower-case letters, digits, '.', '_' or '-' "
					.. "(at most %d characters)",
				connectionId,
				63 - #f.id
			)
		end
	end
	return nil
end

local function trim(s: string): string
	return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", ""))
end

-- The values to store for `auth`, trimmed, or nil and the reason (naming
-- the field, never echoing its value).
function M.validate(auth: Config.Auth, values: { [string]: string }): ({ [string]: string }?, string?)
	local out: { [string]: string } = {}
	for _, f in M.FIELDS[auth] do
		local v = trim(values[f.id] or "")
		if v == "" then
			return nil, f.label .. " is empty"
		end
		if #v > 65536 then
			return nil, f.label .. " is longer than the keychain accepts (64 KiB)"
		end
		if f.multiline then
			if not string.find(v, "^%-%-%-%-%-BEGIN [%u ]*PRIVATE KEY%-%-%-%-%-") then
				return nil, f.label .. " must be a PEM private key (-----BEGIN PRIVATE KEY-----)"
			end
			v ..= "\n"
		elseif string.find(v, "%s") then
			return nil, f.label .. " must not contain spaces or line breaks"
		end
		out[f.id] = v
	end
	return out, nil
end

-- A display stand-in for a typed value: its length only.
function M.mask(value: string): string
	if value == "" then
		return ""
	end
	if #value > 32 then
		return string.rep("•", 8) .. string.format(" (%d characters)", #value)
	end
	return string.rep("•", #value)
end

return M
