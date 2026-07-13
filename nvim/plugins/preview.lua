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
local DEBOUNCE_MS = 150

local timer = nil

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
local function send(path)
	if vim.fn.executable("preview") ~= 1 then
		return
	end
	vim.system({ "preview", "send", path })
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

return {}
