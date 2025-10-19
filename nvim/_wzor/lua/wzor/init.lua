--prepare hydra
-- local hint = "Step over/in/out _J__L__H_ _c_ontinue loc_a_ls _e_val _s_tart _t_erminate _q_uit "

local M = {}

-- Module-level configuration
local empty_prompt = "❯ :"
local multiline_prompt = "∙"
local pane_uid = "nvim_term"

-- Get temp directory for logs
local function get_log_dir()
	local log_dir
	if vim.loop.os_uname().sysname == "Windows_NT" then
		log_dir = os.getenv("TEMP") .. "\\nvim\\wzor\\"
	else
		log_dir = "/tmp/nvim/wzor/"
	end

	-- Ensure directory exists
	vim.fn.mkdir(log_dir, "p")
	return log_dir
end

-- Clear log file
local function clear_log()
	local log_path = get_log_dir() .. "wzor.log"
	local file = io.open(log_path, "w")
	if file then
		file:close()
	end
end

-- Log to temp file (stream mode - appends to single file)
local function log_to_file(data, log_type)
	local log_path = get_log_dir() .. "wzor.log"
	local timestamp = os.date("%Y-%m-%d %H:%M:%S")
	local content = type(data) == "string" and data or vim.json.encode(data)
	local log_entry = string.format("[%s] [%s] %s\n", timestamp, log_type or "INFO", content)

	-- Append to log file
	local file = io.open(log_path, "a")
	if file then
		file:write(log_entry)
		file:close()
	end
	return log_path
end

local function md_block_get()
	local block_line_begin = vim.fn.search("^```[a-z0-9]*$", "bnW")
	local block_line_end = vim.fn.search("^```$", "nW")

	local resp = {}

	resp.lang = vim.fn.getline(block_line_begin):sub(4)
	resp.code = vim.fn.getline(block_line_begin + 1, block_line_end - 1)
	resp.path = vim.fn.expand("%:p:h")

	return resp
end

local function org_block_get()
	local block_line_begin = vim.fn.search("#+begin_src [a-z0-9]*$", "bnW")
	local block_line_end = vim.fn.search("#+end_src$", "nW")

	local resp = {}

	resp.lang = vim.fn.matchlist(vim.fn.getline(block_line_begin), "\\(#+begin_src \\)\\(.*\\)\\?")[3]
	resp.code = vim.fn.getline(block_line_begin + 1, block_line_end - 1)
	resp.path = vim.fn.expand("%:p:h")

	return resp
end

-- local function getLine()
-- 	local cur_position = vim.fn.getcurpos()[2]
--
-- 	local cur_text = vim.api.nvim_buf_get_lines(0, cur_position - 1, cur_position, true)
-- 	return cur_text[1]
-- end

local function temp_path()
	local fname = os.date("%Y%m%d_%H%M%S")
	local tmp_path

	if vim.loop.os_uname().sysname == "Windows_NT" then
		tmp_path = os.getenv("TEMP") .. "\\nvim\\md_blocks\\"
	else
		tmp_path = os.getenv("TEMP") .. "/nvim/md_blocks/"
	end

	return tmp_path .. fname
end

--TODO add check for if pane with id exists

local function run_command_win(block_header)
	-- local tmp_file = temp_path()
	local tmp_file = os.tmpname()

	vim.fn.writefile(block_header, tmp_file)

	local command = string.format(
		-- "nu -c 'open %s | lines | each {|r| wezterm cli send-text --pane-id %d --no-paste $\"($r)\\r\"}'",
		-- "nu -c 'open %s | lines | each {|r| tmux send-keys -t \"neovim:%d\" $\"($r)\" Enter}'",
		-- "tmux send-keys -t \"neovim:%d\" $\"($r)\" Enter",
		tmp_file,
		0 --vim.g.multiplexer_id
	)
	print(command)

	vim.fn.system(command)
end
local function wait_for_prompt(pane, timeout)
	-- pane = pane or "0" -- default to current pane
	timeout = timeout or 60000

	local start_time = vim.loop.hrtime()

	local log = {}
	local iteration = 0
	local response = -1

	local wait_ms = 100

	vim.wait(wait_ms) -- wait check

	while true do
		local output = vim.fn.system("tmux capture-pane -t " .. pane .. " -p")
		output = output:gsub("\n+", "\n") -- Replace multiple newlines with single newlines
		output = output:gsub("\t", "    ") -- Replace tabs with spaces
		output = output:gsub("^%s*", ""):gsub("%s*$", "") -- Trim start and end

		local lines = vim.split(output, "\n")
		local last_line = lines[#lines] or ""

		-- Detect prompt patterns
		local has_main_prompt = last_line == empty_prompt
		local has_multiline_prompt = false

		-- Check if prompt is back (completed) - match at beginning of line
		if has_main_prompt then
			print(last_line .. " completed")
			response = 1 -- completed
		end

		-- Check if it's multiline (new line prompt) - match at beginning of line
		if response == -1 then
			for _, line in ipairs(lines) do
				if line:match("^" .. multiline_prompt) then
					has_multiline_prompt = true
					response = 2
					wait_ms = 50
				else
					wait_ms = 150
				end
			end
		end

		-- Log each iteration
		log_to_file({
			iteration = iteration,
			pane = pane,
			last_line = last_line,
			has_main_prompt = has_main_prompt,
			has_multiline_prompt = has_multiline_prompt,
			response = response,
			wait_ms = wait_ms,
		}, "ITER:wait_for_prompt")

		-- Check timeout
		if response == -1 then
			local elapsed = (vim.loop.hrtime() - start_time) / 1000000 -- convert to ms
			if elapsed > timeout then
				response = 0
				log_to_file({ pane = pane, timeout = timeout, iterations = iteration }, "TIMEOUT:wait_for_prompt")
				return 0 -- timeout
			end
		end

		iteration = iteration + 1

		vim.wait(wait_ms) -- wait before next check

		if response ~= -1 then
			log_to_file({ pane = pane, response = response, iterations = iteration }, "SUCCESS:wait_for_prompt")
			return response
		end
	end
end

local function send_keys_via_buffer(pane, text)
	if text == "" then
		return
	end

	text = text:gsub("\t", "    ") -- Replace tabs with spaces

	-- Create temporary file in wzor temp directory
	local temp_file = get_log_dir() .. "tmux_buffer_" .. os.time()

	-- Write text to file
	local file = io.open(temp_file, "w")
	if file then
		file:write(text)
		file:close()

		-- Load into tmux buffer and paste
		vim.fn.system("tmux load-buffer " .. temp_file)
		vim.fn.system("tmux paste-buffer -t " .. pane)
		vim.fn.system("tmux send-keys -t " .. pane .. " Enter")

		-- Clean up
		os.remove(temp_file)
	end
end

local function run_command(block_header)
	-- Clear log at start of each run
	clear_log()

	local multiplexer_id = 0 -- vim.g.multiplexer_id

	local log = {}

	-- Search for existing pane with this UID
	local target_pane = vim.fn
		.system("tmux list-panes -a -F '#{pane_id} #{@uid}' | grep ' " .. pane_uid .. "$' | head -1 | cut -d' ' -f1")
		:gsub("%s+", "")

	print(target_pane)
	-- If no pane found with this UID, create one
	if target_pane == "" then
		local target = vim.fn
			.system("bash -c 'source ~/.bashrc && start_local_session 1 neovim " .. pane_uid .. "'")
			:gsub("%s+", "")
		target_pane = target
	end

	local pane_id = target_pane

	for i, value in ipairs(block_header) do
		local before_lines = vim.fn.system("tmux display-message -t " .. pane_id .. " -p '#{history_size}'")

		send_keys_via_buffer(pane_id, value)

		local after_lines = vim.fn.system("tmux display-message -t " .. pane_id .. " -p '#{history_size}'")

		local response = wait_for_prompt(pane_id)

		local finished_lines = vim.fn.system("tmux display-message -t " .. pane_id .. " -p '#{history_size}'")

		table.insert(log, {
			index = i,
			command = value,
			response = response,
			lines_before = before_lines:gsub("%s+", ""),
			lines_after = after_lines:gsub("%s+", ""),
			lines_finished = finished_lines:gsub("%s+", ""),
		})

		if response == 0 then
			table.insert(log, { error = "command timeout", at_index = i })
			log_to_file({ pane_id = pane_id, commands = log }, "TIMEOUT:run_command")
			return
		end
	end

	log_to_file({ pane_id = pane_id, commands = log }, "SUCCESS:run_command")
end

M.spawnMultiplexerWindow = function(domain_name)
	local command = string.format("wezterm cli spawn --domain-name %s --new-window --cwd .", domain_name)
	vim.g.multiplexer_id = vim.fn.system(command)
end

M.killMultiplexerWindow = function()
	local command = string.format("wezterm cli kill-pane --pane-id %d", vim.g.multiplexer_id)
	vim.fn.system(command)
end

M.sendLineToMultiplexerWindow = function()
	local cur_text = vim.fn.getline(".")
	print(cur_text)
	local block_header = { cur_text }

	run_command(block_header)
end

M.sendBlockToMultiplexerWindow = function()
	local codeblock = {}

	if vim.bo.filetype == "markdown" then
		codeblock = md_block_get()
	elseif vim.bo.filetype == "org" then
		codeblock = org_block_get()
	else
		print("covered are only .org or .md code blocks")
		return
	end

	print(vim.inspect(codeblock.code))
	run_command(codeblock.code)
end

-- TODO run last command
-- TODO remove vimux

-- local function mdblock_bash(code_block, mdpath)
--
--   --prepare bash
--   local block_header = {
--     "#!/bin/bash",
--     "#get notes root",
--     "NOTES_ROOT='" .. mdpath .. "/'",
--     'if [[ -f "${NOTES_ROOT}.env" ]]; then',
--     '     source "${NOTES_ROOT}.env"',
--     "fi",
--     "#look for active branch in tmux",
--     'ATTACHED_BRANCH="$(tools mpxr attached-branch-path --project-root-path "$PROJECT_ROOT")"',
--     "#try to find environment variables",
--     "if [[ ! -z ${ATTACHED_BRANCH} ]]; then",
--     "     if [[ ! -z ${YAML_VARS} ]]; then",
--     '          eval "$(tools ad pipe var load-to-env --vars-yaml "$PROJECT_ROOT$ATTACHED_BRANCH$YAML_VARS")"',
--     "    fi",
--     "fi",
--     "#----END of automatic header----",
--   }
--   local temp_path = vim.g.lux_temppath() .. vim.g.tmp_file("sh")
--
--   vim.fn.writefile(block_header, temp_path)
--   vim.fn.writefile(code_block, temp_path, "a")
--
--   local cmd = "bash '" .. temp_path .. "'"
--
--   -- vim.fn.VimuxRunCommand(cmd)
--
-- end

return M
