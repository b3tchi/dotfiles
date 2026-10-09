-- ufo-safe fold levels.
-- Native zm/zr/zM/zR change 'foldlevel'. ufo rebuilds folds after every edit
-- and a rebuilt fold deeper than 'foldlevel' comes back closed — so a fold
-- opened with zo snaps shut on the next change. Keep 'foldlevel' at 99 and
-- track a buffer-local "virtual" level applied via ufo.closeFoldsWith().
local M = {}

local function max_level()
	local max = 0
	for l = 1, vim.api.nvim_buf_line_count(0) do
		max = math.max(max, vim.fn.foldlevel(l))
	end
	return max
end

function M.set(level)
	local max = max_level()
	level = math.max(0, math.min(max, level))
	vim.b.ufo_fold_level = level
	vim.wo.foldlevel = 99
	if level >= max then
		require("ufo").openAllFolds()
	else
		require("ufo").closeFoldsWith(level)
	end
end

function M.shift(delta)
	M.set((vim.b.ufo_fold_level or max_level()) + delta * vim.v.count1)
end

-- Catch every other 'foldlevel' writer (:set foldlevel=N, plugins, modelines)
-- and convert it to the virtual level so ufo buffers never run below 99.
function M.setup()
	vim.api.nvim_create_autocmd("OptionSet", {
		pattern = "foldlevel",
		group = vim.api.nvim_create_augroup("ufo_virtual_foldlevel", { clear = true }),
		callback = function()
			local level = tonumber(vim.v.option_new)
			if not level or level >= 99 or not require("ufo").hasAttached() then
				return
			end
			vim.schedule(function()
				M.set(level)
			end)
		end,
	})
end

return M
