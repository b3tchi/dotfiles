--prepare hydra
-- local hint = "Step over/in/out _J__L__H_ _c_ontinue loc_a_ls _e_val _s_tart _t_erminate _q_uit "

local M = {}

-- Module-level configuration
local empty_prompt = "❯ :"
local multiline_prompt = "∙"
local pane_uid = "nvim_term"
local timeout_ms = 60000 -- Default timeout: 60 seconds
local wait_check_ms = 50 -- Wait time between checks
local wait_multiline_ms = 25 -- Wait time when multiline detected
local log_iterations = true -- Log every iteration

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

	-- Direct write to file
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
local function wait_for_prompt(pane, timeout, callback, start_line)
	-- Use module-level timeout if not specified
	timeout = timeout or timeout_ms

	-- Get starting line if not provided
	if not start_line then
		local start_line_str = vim.fn.system("tmux display-message -t " .. pane .. " -p '#{history_size}'"):gsub("%s+", "")
		start_line = tonumber(start_line_str) or 0
	end

	local start_time = vim.loop.hrtime()
	local iteration = 0
	local response = -1

	-- Helper function to check prompt state
	local function check_output()
		-- Get current history size
		local current_line_str = vim.fn.system("tmux display-message -t " .. pane .. " -p '#{history_size}'"):gsub("%s+", "")
		local current_line = tonumber(current_line_str) or 0
		local lines_to_check = math.max(1, current_line - start_line)

		-- Capture only the specific line range from start_line to current (recent output only)
		-- -S start_line: start from history line where command was sent
		-- -E -1: end at last line (current)
		local output = vim.fn.system("tmux capture-pane -t " .. pane .. " -p -S " .. start_line .. " -E -1")
		output = output:gsub("\n+", "\n")
		output = output:gsub("\t", "    ")
		output = output:gsub("^%s*", ""):gsub("%s*$", "")

		local lines = vim.split(output, "\n")
		local last_line = lines[#lines] or ""

		local has_main_prompt = last_line == empty_prompt
		local has_multiline_prompt = false

		if has_main_prompt then
			response = 1
		end

		if response == -1 then
			-- Only check recent lines for multiline prompt
			for _, line in ipairs(lines) do
				if line:match("^" .. multiline_prompt) then
					has_multiline_prompt = true
					response = 2
					break
				end
			end
		end

		return {
			response = response,
			last_line = last_line,
			has_main_prompt = has_main_prompt,
			has_multiline_prompt = has_multiline_prompt,
			lines_checked = lines_to_check,
			current_history = current_line,
		}
	end

	-- Synchronous initial check
	vim.wait(wait_check_ms)
	local result = check_output()

	if log_iterations then
		log_to_file({
			iteration = iteration,
			pane = pane,
			last_line = result.last_line,
			has_main_prompt = result.has_main_prompt,
			has_multiline_prompt = result.has_multiline_prompt,
			response = result.response,
			lines_checked = result.lines_checked,
			start_line = start_line,
			current_history = result.current_history,
			mode = "sync",
		}, "ITER:wait_for_prompt")
	end

	-- If already completed, return immediately
	if result.response ~= -1 then
		log_to_file({ pane = pane, response = result.response, iterations = iteration + 1, last_line = result.last_line }, "SUCCESS:wait_for_prompt")
		if callback then
			callback(result.response)
		end
		return
	end

	-- Command is still pending, go async with slower polling
	iteration = iteration + 1
	local timer = vim.uv.new_timer()
	local timer_closed = false
	local async_wait_ms = 500 -- Slower async polling

	local function close_timer()
		if not timer_closed then
			timer:stop()
			timer:close()
			timer_closed = true
		end
	end

	local function check_prompt_async()
		vim.schedule(function()
			if timer_closed then
				return
			end

			local check_result = check_output()

			if log_iterations then
				log_to_file({
					iteration = iteration,
					pane = pane,
					last_line = check_result.last_line,
					has_main_prompt = check_result.has_main_prompt,
					has_multiline_prompt = check_result.has_multiline_prompt,
					response = check_result.response,
					lines_checked = check_result.lines_checked,
					start_line = start_line,
					current_history = check_result.current_history,
					mode = "async",
				}, "ITER:wait_for_prompt")
			end

			-- Check timeout
			if check_result.response == -1 then
				local elapsed = (vim.loop.hrtime() - start_time) / 1000000
				if elapsed > timeout then
					log_to_file({ pane = pane, timeout = timeout, iterations = iteration }, "TIMEOUT:wait_for_prompt")
					close_timer()
					if callback then
						callback(0)
					end
					return
				end
			end

			iteration = iteration + 1

			if check_result.response ~= -1 then
				log_to_file({ pane = pane, response = check_result.response, iterations = iteration, last_line = check_result.last_line }, "SUCCESS:wait_for_prompt")
				close_timer()
				if callback then
					print(check_result.last_line .. " completed")
					callback(check_result.response)
				end
			end
		end)
	end

	-- Start async timer with 500ms interval
	timer:start(async_wait_ms, async_wait_ms, check_prompt_async)
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
	local command_index = 1

	local function process_next_command()
		if command_index > #block_header then
			log_to_file({ pane_id = pane_id, commands = log }, "SUCCESS:run_command")
			return
		end

		local value = block_header[command_index]
		local before_lines_str = vim.fn.system("tmux display-message -t " .. pane_id .. " -p '#{history_size}'"):gsub("%s+", "")
		local before_lines = tonumber(before_lines_str) or 0

		send_keys_via_buffer(pane_id, value)

		local after_lines_str = vim.fn.system("tmux display-message -t " .. pane_id .. " -p '#{history_size}'"):gsub("%s+", "")
		local after_lines = tonumber(after_lines_str) or 0

		-- Pass the history line number before the command was sent
		wait_for_prompt(pane_id, nil, function(response)
			local finished_lines_str = vim.fn.system("tmux display-message -t " .. pane_id .. " -p '#{history_size}'"):gsub("%s+", "")
			local finished_lines = tonumber(finished_lines_str) or 0

			table.insert(log, {
				index = command_index,
				command = value,
				response = response,
				lines_before = before_lines,
				lines_after = after_lines,
				lines_finished = finished_lines,
			})

			if response == 0 then
				table.insert(log, { error = "command timeout", at_index = command_index })
				log_to_file({ pane_id = pane_id, commands = log }, "TIMEOUT:run_command")
				return
			end

			command_index = command_index + 1
			process_next_command()
		end, before_lines)
	end

	process_next_command()
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

M.startTmuxSession = function()
	-- Use the start_local_session from bash to create a new tmux session
	local result = vim.fn
		.system("bash -c 'source ~/.bashrc && start_local_session 1 neovim " .. pane_uid .. "'")
		:gsub("%s+", "")

	if result ~= "" then
		vim.notify("Started tmux session: " .. result, vim.log.levels.INFO)
		log_to_file({ pane_id = result, action = "session_started" }, "INFO:start_session")
	else
		vim.notify("Failed to start tmux session", vim.log.levels.ERROR)
		log_to_file({ error = "failed to start session" }, "ERROR:start_session")
	end
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
