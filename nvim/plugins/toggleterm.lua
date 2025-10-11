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

		local Terminal = require("toggleterm.terminal").Terminal

		local function _neovim_tmux_toggle()
			-- Get or create the session target
			local target = vim.fn.system("bash -c 'source ~/.bashrc && start_local_session 1 neovim nvim_term'")
			target = vim.trim(target) -- Remove trailing newline

			local neovim_tmux = Terminal:new({
				cmd = "tmux attach-session -t '" .. target .. "'",
				direction = "horizontal",
				close_on_exit = false,
				count = 99,
			})

			neovim_tmux:toggle()
		end

		vim.keymap.set("n", "<leader>tn", _neovim_tmux_toggle, { desc = "Toggle Neovim Tmux Terminal" })
	end,
}
