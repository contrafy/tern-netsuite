--!strict
-- The pane size a block can rely on. Tern 0.7.0 creates every plugin block
-- with cx.cols/cx.rows at its 80x24 placeholder and never calls `resize` or
-- updates them, whatever the real size (measured in a sandbox: open beside,
-- below, in a tab, zoomed or after a window resize). Views therefore never
-- size row lists from the height (ui.scroll fills the pane instead) and only
-- use a size Tern actually measured, for column layouts and paging.

local M = {}

M.PLACEHOLDER_COLS = 80
M.PLACEHOLDER_ROWS = 24

-- `cols`, `rows` when they describe the pane: after a `resize` callback, or
-- any size other than the placeholder; nil, nil when unknown.
function M.size(cols: number, rows: number, resized: boolean): (number?, number?)
	if resized or cols ~= M.PLACEHOLDER_COLS or rows ~= M.PLACEHOLDER_ROWS then
		return cols, rows
	end
	return nil, nil
end

return table.freeze(M)
