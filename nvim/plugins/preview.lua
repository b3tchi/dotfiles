-- Pushes the file under the cursor to the preview-d daemon (ft005) so the
-- floating preview window (`preview<N>`) follows editor navigation — the
-- editor -> daemon half of the cursor-driven preview bridge (sp008 Task 5).
--
-- CursorMoved fires on every cursor step, so it is debounced (edge case:
-- "very fast cursor motion — debounce so we don't flood"); CursorHold
-- already only fires after nvim's own `updatetime` pause, so it sends
-- immediately without an extra debounce layer. Together they cover both
-- "settled on a line" (CursorHold) and "actively sweeping references"
-- (debounced CursorMoved) per the sp008 solution.
--
-- Only calls the mandatory nushell wrapper (`preview send <path>`,
-- adr0001 nushell-first surface, adr0003 mandatory-wrapper mandate) — this
-- file never talks to the preview-d daemon directly.
--
-- sp009 Task 3: multiple nvim instances can each drive their own preview
-- slot instead of every instance fighting over the hardcoded window 1.
-- `registered_slot` holds the slot this nvim instance was assigned by
-- preview-d's POST /register (via the `preview register` wrapper verb,
-- sp009 Task 1); `send()` targets that slot once known, falling back to
-- the wrapper's own default (window 1) before registration completes.
local DEBOUNCE_MS = 150

local timer = nil
local registered_slot = nil

--- True when the buffer is a real, on-disk file worth pushing to the
--- preview window — excludes `[No Name]`/scratch buffers (empty name) and
--- non-file buftypes (terminal, help, quickfix, nofile, ...) per sp008
--- Task 5 edge cases.
local function should_send(buf)
	if vim.bo[buf].buftype ~= "" then
		return false
	end
	return vim.api.nvim_buf_get_name(buf) ~= ""
end

--- Fire-and-forget POST via the mandatory wrapper. Best-effort: a preview
--- push must never interrupt editing, so failures (daemon not running,
--- wrapper missing) are swallowed rather than surfaced on every cursor
--- move — `preview status` is the place to diagnose a dead daemon.
---
--- Targets this instance's own slot (`registered_slot`, sp009 Task 3) once
--- `:PreviewStart` has registered one; before that (or if registration
--- failed) it omits `--window` and lets the wrapper fall back to its
--- default slot 1 rather than erroring on every cursor move.
local function send(path)
	if vim.fn.executable("preview") ~= 1 then
		return
	end
	local args = { "preview", "send", path }
	if registered_slot then
		table.insert(args, "--window")
		table.insert(args, tostring(registered_slot))
	end
	vim.system(args)
end

local function send_current_buffer()
	local buf = vim.api.nvim_get_current_buf()
	if not should_send(buf) then
		return
	end
	send(vim.api.nvim_buf_get_name(buf))
end

vim.api.nvim_create_autocmd("CursorHold", {
	desc = "preview: push the settled-on file to the preview window",
	callback = send_current_buffer,
})

vim.api.nvim_create_autocmd("CursorMoved", {
	desc = "preview: push the file under the cursor, debounced",
	callback = function()
		local buf = vim.api.nvim_get_current_buf()
		if not should_send(buf) then
			return
		end
		if timer then
			timer:stop()
			timer:close()
		end
		timer = vim.uv.new_timer()
		timer:start(
			DEBOUNCE_MS,
			0,
			vim.schedule_wrap(function()
				send(vim.api.nvim_buf_get_name(buf))
			end)
		)
	end,
})

-- Reverse channel (sp008 Task 6): the daemon's `POST /open` handler drives
-- `nvim --server $NVIM --remote <path>` — it reads $NVIM from its OWN
-- process environment, not from any running nvim's internal state. That
-- only resolves to a live server if the daemon process itself inherited
-- $NVIM from an nvim instance, which requires the daemon to have been
-- launched as a child of THAT nvim (nvim injects $NVIM into the env of
-- jobs/terminals it starts) rather than from an unrelated shell.
--
-- `:PreviewStart` is the helper that makes that true: it launches the
-- preview-d daemon (via the mandatory `preview` wrapper, adr0003) as a
-- detached job of this nvim instance, so the daemon's environment carries
-- this nvim's `$NVIM`/`v:servername` and the webview's `POST /open` can
-- find its way back here. `ensure_server` guards the rare case where this
-- nvim instance has no server address yet (e.g. started with an explicit
-- empty --listen) — serverstart() with no args uses nvim's own default
-- address scheme.
local function ensure_server()
	if vim.v.servername == "" or vim.v.servername == nil then
		vim.fn.serverstart()
	end
end

--- Register this nvim's server address against a slot via the mandatory
--- `preview register` wrapper verb (sp009 Task 1/3), storing the daemon's
--- assigned slot in `registered_slot` so `send()` can target it.
---
--- Idempotent: if this instance already holds a slot (a prior
--- `:PreviewStart` in the same session), that slot is passed back
--- explicitly via `--slot` so the daemon rebinds the same slot to the
--- (possibly refreshed) address instead of allocating a new one — sp009
--- Task 3 edge case: "second PreviewStart in the same nvim → idempotent".
---
--- Synchronous (`:wait()`): registration must complete before `send()`
--- can target the right slot, and the wrapper's own 2s http timeout
--- bounds the wait. Failures (daemon down, wrapper missing, malformed
--- response) surface via `vim.notify` rather than failing silently —
--- sp009 Task 3 edge case: "register while daemon down ... a clear
--- surfaced error, not silent failure".
local function register(addr)
	if vim.fn.executable("preview") ~= 1 then
		vim.notify("preview: 'preview' wrapper not found on PATH", vim.log.levels.ERROR)
		return
	end
	local args = { "preview", "register", addr }
	if registered_slot then
		table.insert(args, "--slot")
		table.insert(args, tostring(registered_slot))
	end
	local result = vim.system(args, { text = true }):wait()
	if result.code ~= 0 then
		vim.notify(
			"preview: register failed — " .. ((result.stderr or "") .. (result.stdout or "")),
			vim.log.levels.ERROR
		)
		return
	end
	local slot = tonumber(vim.trim(result.stdout or ""))
	if not slot then
		vim.notify("preview: register returned no usable slot: " .. (result.stdout or ""), vim.log.levels.ERROR)
		return
	end
	registered_slot = slot
end

--- Spawn this instance's own slot window via the mandatory `preview
--- window <N>` wrapper verb (sp013 Task 2). Idempotent per slot (the
--- wrapper's pidfile lifecycle): a second `:PreviewStart` in the same
--- nvim instance no-ops against the already-running window instead of
--- opening a duplicate (sp013 Task 3 success criterion); a window closed
--- by hand is treated as stale and respawned on the next call.
---
--- Only ever called with a slot that `register()` actually assigned —
--- callers must guard on `registered_slot` first, so a failed
--- registration never attempts a spawn (sp013 Task 3 edge case).
---
--- Synchronous (`:wait()`): the wrapper's own probe/pidfile lifecycle
--- (daemon-down / missing-binary checks) bounds the wait, same as
--- `register` above. Failure surfaces via `vim.notify` but never returns
--- an error to the caller — spawn failure must leave editing unaffected.
local function spawn_window(slot)
	local result = vim.system({ "preview", "window", tostring(slot) }, { text = true }):wait()
	if result.code ~= 0 then
		vim.notify(
			"preview: window spawn failed — " .. ((result.stderr or "") .. (result.stdout or "")),
			vim.log.levels.ERROR
		)
	end
end

vim.api.nvim_create_user_command("PreviewStart", function()
	ensure_server()
	if vim.fn.executable("preview") ~= 1 then
		vim.notify("preview: 'preview' wrapper not found on PATH", vim.log.levels.ERROR)
		return
	end
	-- Synchronous: the wrapper's `start` verb gates on the daemon answering
	-- /status (readiness poll, dotfiles-nbt), so waiting here is what makes
	-- the register below race-free on the fresh-start path. `detach` keeps
	-- the wrapper (and the daemon it nohups) out of this nvim's job table.
	local started = vim.system({ "preview", "start" }, { detach = true, text = true }):wait()
	if started.code ~= 0 then
		vim.notify(
			"preview: start failed — " .. ((started.stderr or "") .. (started.stdout or "")),
			vim.log.levels.ERROR
		)
		return
	end
	register(vim.v.servername)
	-- registered_slot is only set once register() succeeds — a failed
	-- registration leaves it nil (or unchanged on a re-run) and this
	-- instance never attempts to open a window (sp013 Task 3 edge case).
	if registered_slot then
		spawn_window(registered_slot)
	end
end, { desc = "preview: start preview-d as a child of this nvim (so $NVIM reaches it for the reverse /open channel), register this instance's own preview slot, and spawn that slot's webview window" })

vim.api.nvim_create_user_command("PreviewStop", function()
	if vim.fn.executable("preview") ~= 1 then
		return
	end
	vim.system({ "preview", "stop" })
end, { desc = "preview: stop preview-d" })

return {}
