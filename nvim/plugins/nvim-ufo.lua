return {
	"kevinhwang91/nvim-ufo",
	dependencies = { "kevinhwang91/promise-async" },
	init = function()
		vim.o.fillchars = [[eob: ,fold: ,foldopen:-,foldsep: ,foldclose:+]]
		-- vim.o.fillchars = [[eob: ,fold: ,foldopen:,foldsep: ,foldclose:]]
		vim.o.foldcolumn = "1" -- '0' is not bad
		vim.o.foldlevel = 99 -- Using ufo provider need a large value, feel free to decrease the value
		vim.o.foldlevelstart = -1
		vim.o.foldenable = true
	end,
	config = function()
		require("ufo").setup({
			provider_selector = function(bufnr, filetype, buftype)
				return { "treesitter", "indent" }
			end,
			preview = {
				win_config = {
					border = { "", "─", "", "", "", "─", "", "" },
					winhighlight = "Normal:Folded",
					winblend = 0,
				},
				get_config = function(winid)
					local win_height = vim.api.nvim_win_get_height(winid)
					local win_width = vim.api.nvim_win_get_width(winid)
					return {
						relative = "win",
						anchor = "NW",
						win = winid,
						row = win_height,
						col = 0,
						width = win_width,
						height = math.min(10, vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))),
					}
				end,
				mappings = {
					scrollU = "<C-u>",
					scrollD = "<C-d>",
					jumpTop = "gg",
					jumpBot = "G",
				},
			},
		})
	end,
}
