-- return {
-- 	'akinsho/toggleterm.nvim',
-- }
return {
	"akinsho/toggleterm.nvim",
	keys = {
		{ "<leader>mn", desc = "Neovim Tmux Terminal" },
	},
	config = function()
		require("toggleterm").setup()

		local Terminal = require("toggleterm.terminal").Terminal

		local function _neovim_tmux_toggle()
			-- Get or create the session target using the script directly
			local target = vim.fn.system("~/.local/bin/tmux-start start 1 neovim nvim_term")
			target = vim.trim(target) -- Remove trailing newline

			-- Extract session name and window index from format "session:window"
			local session, window = target:match("([^:]+):(%d+)")

			-- Build the tmux command - need to wrap in bash to properly handle the semicolon
			local tmux_cmd
			if session and window then
				-- Use bash -c to properly execute the tmux command with semicolon
				tmux_cmd = string.format("bash -c 'tmux attach-session -t %s \\; select-window -t %s'", session, window)
			else
				-- Fallback to just session name if parsing fails
				tmux_cmd = "tmux attach-session -t " .. session
			end

			local neovim_tmux = Terminal:new({
				cmd = tmux_cmd,
				direction = "horizontal",
				close_on_exit = false,
				count = 99,
			})

			neovim_tmux:toggle()
		end

		vim.keymap.set("n", "<leader>mn", _neovim_tmux_toggle, { desc = "Toggle Neovim Tmux Terminal" })
	end,
}
