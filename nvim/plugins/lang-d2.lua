-- Live browser preview for d2 files via d2-router-d daemon.
--
-- <leader>cp  (registered project)  — ensure daemon, resolve route, open URL
-- <leader>cp  (outside projects)    — fallback: per-buffer d2 --watch (legacy)
-- <leader>cP  (registered project)  — POST /api/reload for buffer's route
-- <leader>cP  (fallback watcher)    — stop legacy per-buffer watcher
--
-- All HTTP calls are async via vim.system curl. Failures surface via vim.notify
-- with the failing step named. No blocking UI calls.
vim.api.nvim_create_autocmd("FileType", {
	pattern = "d2",
	callback = function(ev)
		-- ── helpers ────────────────────────────────────────────────────────────

		--- Return the router base URL (reads D2_ROUTER_PORT, defaults 4800).
		local function router_base()
			local port = vim.env.D2_ROUTER_PORT or "4800"
			return "http://127.0.0.1:" .. port
		end

		--- Check whether curl is on PATH.
		local function curl_available()
			return vim.fn.executable("curl") == 1
		end

		-- ── legacy per-buffer watcher (kept as named functions for fallback) ──

		local function start_watch()
			local file = vim.api.nvim_buf_get_name(ev.buf)
			if file == "" then
				vim.notify("d2: save the file first", vim.log.levels.WARN)
				return
			end
			if vim.b[ev.buf].d2_watch_job and vim.fn.jobwait({ vim.b[ev.buf].d2_watch_job }, 0)[1] == -1 then
				-- Already watching: don't re-open the browser. The running server
				-- hot-reloads on save, so leave the existing tab alone.
				vim.notify(
					"d2: watch already running"
						.. (vim.b[ev.buf].d2_watch_url and (" — " .. vim.b[ev.buf].d2_watch_url) or ""),
					vim.log.levels.INFO
				)
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

		-- ── router integration ─────────────────────────────────────────────────

		--- Async: start d2-router daemon (idempotent). Calls on_done(ok, err_msg).
		local function router_start(on_done)
			if vim.fn.executable("d2-router") ~= 1 then
				on_done(false, "d2-router not found — run: rotz install d2")
				return
			end
			vim.system({ "d2-router", "start" }, { text = true }, function(result)
				if result.code ~= 0 then
					local msg = (result.stderr ~= "" and result.stderr) or result.stdout or "unknown error"
					on_done(false, "d2-router start: " .. msg)
				else
					on_done(true, nil)
				end
			end)
		end

		--- Async: resolve absolute path via GET /api/resolve?path=<file>.
		--- Calls on_done(route_info, err_msg); route_info = {project, file, url} or nil.
		local function router_resolve(abs_path, on_done)
			if not curl_available() then
				on_done(nil, "curl not found — install curl to use router integration")
				return
			end
			local url = router_base() .. "/api/resolve?path=" .. vim.uri_encode(abs_path)
			vim.system(
				{ "curl", "--silent", "--fail", "--max-time", "5", url },
				{ text = true },
				function(result)
					if result.code ~= 0 then
						-- Non-zero exit from curl --fail: 4xx/5xx (code 22) or connection
						-- refused (code 7) — path is outside projects or daemon unreachable.
						on_done(nil, "resolve: daemon not reachable or path not in a registered project")
						return
					end
					local ok, parsed = pcall(vim.json.decode, result.stdout)
					if not ok or type(parsed) ~= "table" or not parsed.url then
						on_done(nil, "resolve: unexpected response from daemon")
						return
					end
					on_done(parsed, nil)
				end
			)
		end

		--- Async: POST /api/reload/{project}/{filename}. Calls on_done(ok, err_msg).
		local function router_reload(project, filename, on_done)
			if not curl_available() then
				on_done(false, "curl not found — install curl to use router integration")
				return
			end
			local url = router_base() .. "/api/reload/" .. project .. "/" .. filename
			vim.system(
				{ "curl", "--silent", "--fail", "--max-time", "5", "-X", "POST", url },
				{ text = true },
				function(result)
					if result.code ~= 0 then
						local msg = (result.stderr ~= "" and result.stderr) or "HTTP error"
						on_done(false, "reload: " .. msg)
					else
						on_done(true, nil)
					end
				end
			)
		end

		--- Full router preview flow: start daemon → resolve path → open URL.
		--- On daemon start failure, falls back to the legacy per-buffer watcher + warns.
		--- On resolve failure (outside projects), falls back silently (expected case).
		local function start_watch_router(file)
			router_start(function(ok, err)
				if not ok then
					vim.schedule(function()
						vim.notify(
							"d2: daemon start failed (" .. err .. ") — falling back to per-buffer watch",
							vim.log.levels.WARN
						)
						start_watch()
					end)
					return
				end
				router_resolve(file, function(route, rerr)
					if not route then
						-- Path is outside all registered projects → legacy fallback (expected).
						vim.schedule(function()
							vim.notify(
								"d2: " .. rerr .. " — falling back to per-buffer watch",
								vim.log.levels.INFO
							)
							start_watch()
						end)
						return
					end
					-- Success: store route info on buffer, open URL in browser.
					vim.schedule(function()
						vim.b[ev.buf].d2_router_route = route
						-- Repeated <leader>cp → re-show URL, no duplicate tab.
						if vim.b[ev.buf].d2_router_url_opened == route.url then
							vim.notify("d2: already open — " .. route.url, vim.log.levels.INFO)
							return
						end
						vim.b[ev.buf].d2_router_url_opened = route.url
						vim.notify("d2: opening " .. route.url, vim.log.levels.INFO)
						vim.ui.open(route.url)
					end)
				end)
			end)
		end

		-- ── keymaps ────────────────────────────────────────────────────────────

		--- <leader>cp — open live preview.
		--- Tries the router flow first (async). Falls back to legacy per-buffer
		--- watch when the file is outside all registered projects or the daemon
		--- binary is absent.
		vim.keymap.set("n", "<leader>cp", function()
			local file = vim.api.nvim_buf_get_name(ev.buf)
			if file == "" then
				vim.notify("d2: save the file first", vim.log.levels.WARN)
				return
			end
			start_watch_router(file)
		end, { buffer = ev.buf, desc = "d2 live preview (browser)" })

		--- <leader>cP — force reload (router) or stop watcher (legacy fallback).
		vim.keymap.set("n", "<leader>cP", function()
			local route = vim.b[ev.buf].d2_router_route
			if route and route.project and route.file then
				-- Router-managed buffer: POST /api/reload.
				router_reload(route.project, route.file, function(ok, err)
					vim.schedule(function()
						if ok then
							vim.notify(
								"d2: reloaded " .. route.project .. "/" .. route.file,
								vim.log.levels.INFO
							)
						else
							vim.notify("d2: " .. (err or "reload failed"), vim.log.levels.WARN)
						end
					end)
				end)
			else
				-- Legacy fallback buffer: stop the per-buffer watcher.
				stop_watch()
			end
		end, { buffer = ev.buf, desc = "d2 reload preview (router) / stop watch (legacy)" })
	end,
})

return {
	"ravsii/tree-sitter-d2",
	dependencies = { "nvim-treesitter/nvim-treesitter" },
	version = "*", -- use the latest git tag instead of main
	build = "make nvim-install",
}
