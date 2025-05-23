return {
	"brenoprata10/nvim-highlight-colors",
	-- "uga-rosa/ccc.nvim",
	-- branch = "0.7.2",
	init = function()
		vim.opt.termguicolors = true
	end,
	keys = {
      -- add a keymap to browse plugin files
      -- stylua: ignore
      {
        "<leader>uH",
        function() require("nvim-highlight-colors").toggle() end,
        desc = "highlight colors",
      },
	},
}
