return {
	"dhruvasagar/vim-table-mode",
	init = function()
		-- <leader>t belongs to the TableMode hydra (plugins/hydra.lua)
		vim.g.table_mode_map_prefix = "<leader>T"
	end,
}
