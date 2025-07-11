-- return {
-- 	'akinsho/toggleterm.nvim',
-- }
return {
	"akinsho/toggleterm.nvim",
	keys = {
		{ "<leader>tn", desc = "Neovim Tmux Terminal" },
	},
	config = function()
		require("toggleterm").setup()

		local Terminal = require('toggleterm.terminal').Terminal

		local neovim_tmux = Terminal:new({
			cmd = "tmux new-session -A -s neovim",
			direction = "horizontal",
			close_on_exit = false,
			count = 99,
		})

		function _neovim_tmux_toggle()
			neovim_tmux:toggle()
		end

		vim.keymap.set("n", "<leader>tn", _neovim_tmux_toggle, { desc = "Toggle Neovim Tmux Terminal" })
	end,
}
