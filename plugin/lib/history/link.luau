--!strict
-- `tern-netsuite://history/...` links from the history block to the window,
-- which can split panes (blocks cannot). The window builds a shell command
-- from a parsed link, so both fields are validated to plain characters.

local Encoding = require("../ns/encoding")

export type Link = { kind: "failed-log", repo: string, run: number }

local M = {}

M.PREFIX = "tern-netsuite://history/"

function M.failedLog(repo: string, run: number): string
	return M.PREFIX .. "failed-log?" .. Encoding.query({ { "repo", repo }, { "run", string.format("%d", run) } })
end

function M.parse(url: string): Link?
	if string.sub(url, 1, #M.PREFIX) ~= M.PREFIX then
		return nil
	end
	local kind, query = string.match(string.sub(url, #M.PREFIX + 1), "^([%w%-]+)%?(.*)$")
	if kind ~= "failed-log" or query == nil then
		return nil
	end
	local params: { [string]: string } = {}
	for pair in string.gmatch(query, "[^&]+") do
		local k, v = string.match(pair, "^([^=]+)=(.*)$")
		if k and v then
			params[Encoding.decode(k)] = Encoding.decode(v)
		end
	end
	local repo = params.repo
	local run = params.run
	if
		repo == nil
		or run == nil
		or not string.match(repo, "^[%w%-_%.]+/[%w%-_%.]+$")
		or not string.match(run, "^%d+$")
		or #run > 20
	then
		return nil
	end
	return { kind = "failed-log", repo = repo, run = tonumber(run) :: number }
end

return M
