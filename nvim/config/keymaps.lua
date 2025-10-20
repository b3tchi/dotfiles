-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
-- vim.keymap.del("n", "<C-h>")
-- vim.keymap.del("n", "<C-j>")
-- vim.keymap.del("n", "<C-k>")
-- vim.keymap.del("n", "<C-l>")

vim.keymap.set("i", "jj", "<ESC>", { noremap = true, silent = true, desc = "<ESC>" })

vim.keymap.set(
	"n",
	"<leader>rc",
	":%s/<C-r><C-w>//gc<Left><Left><Left>",
	{ noremap = true, silent = true, desc = "replace word under cursor" }
)
vim.keymap.set(
	"n",
	"<leader>rr",
	':%s/<C-r>"//gc<Left><Left><Left>',
	{ noremap = true, silent = true, desc = "replace word from clipboard" }
)

--keep clipboard same when pasting over content
vim.keymap.set("x", "p", function()
	return 'pgv"' .. vim.v.register .. "y"
end, { remap = false, expr = true })
-- vim.keymap.set("n", "<leader>dH", "<leader>dh", { noremap = true, silent = true, desc = "triggerDh" })
-- nnoremap <space>rc :%s/<C-r><C-w>//gc<Left><Left><Left>
-- nnoremap <space>rr :%s/<C-r>"//gc<Left><Left><Left>

vim.keymap.set("n", "<leader>ws", "<C-w>v", { noremap = true, silent = true, desc = "split window side" })
vim.keymap.set("n", "<leader>wb", "<C-w>s", { noremap = true, silent = true, desc = "split window bellow" })

-- Store file watchers per buffer
local file_watchers = {}

-- Toggle auto-reload for current buffer with file watching
local function toggle_auto_reload()
	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)

	if file_watchers[bufnr] then
		-- Disable: stop the file watcher
		if file_watchers[bufnr].handle then
			file_watchers[bufnr].handle:stop()
			file_watchers[bufnr].handle:close()
		end
		file_watchers[bufnr] = nil
		vim.bo.autoread = false

		vim.notify("Auto-reload disabled for buffer", vim.log.levels.INFO)
	else
		-- Enable: start file watcher using libuv
		vim.bo.autoread = true

		local handle = vim.loop.new_fs_event()
		if handle then
			handle:start(
				filepath,
				{},
				vim.schedule_wrap(function(err, filename, events)
					if err then
						vim.notify("File watcher error: " .. err, vim.log.levels.ERROR)
						return
					end

					-- Check if buffer is still valid and file exists
					if vim.api.nvim_buf_is_valid(bufnr) then
						vim.cmd("checktime " .. bufnr)
					end
				end)
			)

			file_watchers[bufnr] = { handle = handle, filepath = filepath }
			vim.notify("Auto-reload enabled for buffer (watching: " .. vim.fn.fnamemodify(filepath, ":t") .. ")", vim.log.levels.INFO)
		else
			vim.notify("Failed to create file watcher", vim.log.levels.ERROR)
		end
	end

	-- Update the keymap description
	vim.keymap.set("n", "<leader>bw", toggle_auto_reload, {
		noremap = true,
		silent = true,
		desc = file_watchers[bufnr] and "Toggle watch Off" or "Toggle watch On",
	})
end

vim.keymap.set("n", "<leader>bw", toggle_auto_reload, {
	noremap = true,
	silent = true,
	desc = "Toggle watch On",
})

-- Clean up file watchers when buffer is deleted
vim.api.nvim_create_autocmd("BufDelete", {
	callback = function(args)
		local bufnr = args.buf
		if file_watchers[bufnr] then
			if file_watchers[bufnr].handle then
				file_watchers[bufnr].handle:stop()
				file_watchers[bufnr].handle:close()
			end
			file_watchers[bufnr] = nil
		end
	end,
})

-- nnoremap <space>ws <c-w>v
-- nnoremap <space>wb <c-w>s
vim.cmd([[highlight @markup.heading.1.markdown guifg=#c0caf5 gui=bold]])
vim.cmd([[highlight @markup.heading.2.markdown guifg=#c0caf5 gui=bold]])
vim.cmd([[highlight @markup.heading.3.markdown guifg=#c0caf5 gui=bold]])
vim.cmd([[highlight @markup.heading.4.markdown guifg=#c0caf5 gui=bold]])
vim.cmd([[highlight @markup.heading.5.markdown guifg=#c0caf5 gui=bold]])
vim.cmd([[highlight @markup.heading.6.markdown guifg=#c0caf5 gui=bold]])
