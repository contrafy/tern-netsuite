--!strict
-- The pane size a block can rely on. Tern creates every plugin block with
-- cx.cols/cx.rows at an 80x24 placeholder. Tern 0.8.3 then calls `resize`
-- with the real size (and updates cx) right after the first view, and again
-- whenever the pane changes (split, zoom, tab, window resize; measured in a
-- sandbox). Tern 0.7.0 never did, so the placeholder alone is never trusted:
-- a size counts after a `resize` callback or when it differs from it.

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
