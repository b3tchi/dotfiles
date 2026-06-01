-- Live browser preview for d2 files. `d2 --watch FILE` runs a local web server
-- that redraws on every save. We launch it as a child job (killed when nvim
-- exits, so the server stops with the editor) and surface the URL it prints.
-- One watcher per buffer; pressing the key again just re-shows the URL.
vim.api.nvim_create_autocmd("FileType", {
	pattern = "d2",
	callback = function(ev)
		local function start_watch()
			local file = vim.api.nvim_buf_get_name(ev.buf)
			if file == "" then
				vim.notify("d2: save the file first", vim.log.levels.WARN)
				return
			end
			if vim.b[ev.buf].d2_watch_job and vim.fn.jobwait({ vim.b[ev.buf].d2_watch_job }, 0)[1] == -1 then
				-- Already watching: re-open the browser to refresh/refocus the view.
				-- (The server already hot-reloads on save; this just brings the tab back.)
				local url = vim.b[ev.buf].d2_watch_url
				if url then
					vim.ui.open(url)
					vim.notify("d2: refreshed view — " .. url, vim.log.levels.INFO)
				else
					vim.notify("d2: watch running, URL not captured yet", vim.log.levels.WARN)
				end
				return
			end
			local function on_out(_, data)
				for _, line in ipairs(data or {}) do
					local url = line:match("https?://%S+")
					if url then
						vim.b[ev.buf].d2_watch_url = url
						vim.notify("d2 watch: " .. url, vim.log.levels.INFO)
					end
				end
			end
			vim.b[ev.buf].d2_watch_job = vim.fn.jobstart({ "d2", "--watch", file }, {
				on_stdout = on_out,
				on_stderr = on_out,
			})
		end

		local function stop_watch()
			local job = vim.b[ev.buf].d2_watch_job
			if job and vim.fn.jobwait({ job }, 0)[1] == -1 then
				vim.fn.jobstop(job)
				vim.b[ev.buf].d2_watch_job = nil
				vim.notify("d2: watch stopped", vim.log.levels.INFO)
			else
				vim.notify("d2: no watch running", vim.log.levels.WARN)
			end
		end

		vim.keymap.set("n", "<leader>cp", start_watch, { buffer = ev.buf, desc = "d2 live preview (browser)" })
		vim.keymap.set("n", "<leader>cP", stop_watch, { buffer = ev.buf, desc = "d2 stop preview" })
	end,
})

return {
	"ravsii/tree-sitter-d2",
	dependencies = { "nvim-treesitter/nvim-treesitter" },
	version = "*", -- use the latest git tag instead of main
	build = "make nvim-install",
}
