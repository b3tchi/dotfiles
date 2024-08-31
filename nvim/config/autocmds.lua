-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
-- Add any additional autocmds here
vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
	callback = function()
		vim.b.last_focused_time = vim.loop.hrtime() / 1e6
	end,
})
