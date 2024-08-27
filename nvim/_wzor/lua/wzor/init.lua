--prepare hydra
-- local hint = "Step over/in/out _J__L__H_ _c_ontinue loc_a_ls _e_val _s_tart _t_erminate _q_uit "

local M = {}

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

local function getLine()
  local cur_position = vim.fn.getcurpos()[2]

  local cur_text = vim.api.nvim_buf_get_lines(0,cur_position-1,cur_position, true)
  return cur_text[1]
end

local function temp_path()
  local fname = os.date("%Y%m%d_%H%M%S")
  local tmp_path = os.getenv("TEMP") .. "\\nvim\\md_blocks\\"

  vim.fn.mkdir(tmp_path, "p")

  return tmp_path .. fname
end

--TODO add check for if pane with id exists

local function run_command(block_header)

  local tmp_file = temp_path()

  vim.fn.writefile(block_header, tmp_file)

  local command
  if vim.loop.os_uname().sysname == "Windows_NT" then
    command = string.format('powershell -c "Get-Content \'%s\' | wezterm cli send-text --pane-id %d --no-paste "', tmp_file , vim.g.multiplexer_id)
  end
  -- print(command)

  vim.fn.system(command)

end
M.spawnMultiplexerWindow= function(domain_name)
  local command = string.format('wezterm cli spawn --domain-name %s --new-window --cwd .', domain_name)
  vim.g.multiplexer_id = vim.fn.system(command)
end

M.killMultiplexerWindow = function()
  local command = string.format('wezterm cli kill-pane --pane-id %d' ,vim.g.multiplexer_id)
  vim.fn.system(command)
end


M.sendLineToMultiplexerWindow = function()

  local cur_text = vim.fn.getline(".") 
  print (cur_text)
  local block_header = {cur_text}

  run_command(block_header)

end

M.sendBlockToMultiplexerWindow = function()
  local mdblock = {}

  if vim.bo.filetype == "markdown" then
    mdblock = md_block_get()
  elseif vim.bo.filetype == "org" then
    mdblock = org_block_get()
  else
    print("covered are only .org or .md code blocks")
    return
  end

  print(vim.inspect(mdblock.code))
  run_command(mdblock.code)

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

