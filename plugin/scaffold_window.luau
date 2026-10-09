--!strict
-- Window glue for the scaffolder: the palette command opens the `scaffold`
-- block beside the focused pane, for that pane's working directory.

local M = {}

M.BLOCK = "tern-netsuite.scaffold"

local function focusedCwd(cx: WindowCx): string?
	local ok, info = pcall(function()
		local id = cx.session:focused()
		return if id then cx.session:pane(id) else nil
	end)
	local cwd = if ok and info then info.cwd else nil
	return if type(cwd) == "string" and string.sub(cwd, 1, 1) == "/" then cwd else nil
end

function M.register()
	tern.command({
		id = "new-script",
		title = "Tern NetSuite: New script",
		icon = "cloud",
		run = function(cx: WindowCx)
			local cwd = focusedCwd(cx)
			if cx:new_block(M.BLOCK, if cwd then { cwd } else {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite is not loaded on this host")
			end
		end,
	})
end

return M
