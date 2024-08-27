--prepare hydra
local hint = "Step over/in/out _J__L__H_ _c_ontinue loc_a_ls _e_val _s_tart _t_erminate _q_uit "

local M = {}

require("hydra")({
  name = "DebugPwshHack",
  hint = hint,
  config = {
    color = "pink",
    invoke_on_body = true,
    buffer = true,
    hint = {
      type = "window",
    },
  },
  mode = { "n" },
  body = "<leader>dh",
  heads = {
    { "H", "<cmd>lua vim.fn.chansend(vim.g.ps_terminal_jobid ,'o\\r')<CR>", { silent = true, desc = "step out" } },
    { "J", "<cmd>lua vim.fn.chansend(vim.g.ps_terminal_jobid ,'v\\r')<CR>", { silent = true, desc = "step over" } },
    { "L", "<cmd>lua vim.fn.chansend(vim.g.ps_terminal_jobid ,'s\\r')<CR>", { silent = true, desc = "step into" } },

    { "e", "<cmd>lua require('dapui').eval(vim.fn.expand('cWORD'))<CR>", { silent = true, desc = "float variables" } },
    { "a", "<cmd>lua require('dapui').float_element('scopes',{enter = true})<CR>", { silent = true, desc = "float variables" } },
    { "c", "<cmd>lua vim.fn.chansend(vim.g.ps_terminal_jobid,'c\\r')<CR>", { silent = true, desc = "continue" } },

    { "s", "<cmd>lua require('myfxs').startPsDebug()<CR>", { silent = true, nowait = true, desc = "strat" } },

    { "t", "<cmd>lua require('myfxs').terminatePsDebug()<CR>", { silent = true, exit = true, nowait = true, desc = "exit" } },
    { "q", nil, { exit = true, nowait = true, desc = "exit" } },
  },
})

M.startPsDebug = function()

  local session_path = "C:/Users/czjabeck/AppData/Local/Temp/nvim"
  local session_file = session_path .. "/session.json"
  
  --delete file before just to be sure
  local success, err = os.remove(session_file)
  if success then
    print("File deleted successfully.")
  else
    -- If there was an error, you can decide how to handle it
    -- For example, if the file didn't exist, it's not necessarily a problem
    if err then print("Error deleting file: ", err) end
  end
  
 
  -- vim.api.nvim_create_augroup("WaitForSessionFile", {clear = true})
  -- vim.api.nvim_create_autocmd("BufWritePost", {
  --   group = "WaitForSessionFile",
  --   pattern = session_file, -- Adjust the pattern to match your session file name
  --   callback = onFileCreate,
  -- })



  local PSES_BUNDLE_PATH = "C:/Users/czjabeck/AppData/Local/nvim-data/mason/packages/powershell-editor-services"

  local pipe_name = string.format("test-pipe-%d",math.random(1000,6000))

  local command = {"pwsh",
    "-NoLogo",
    "-NoProfile",
    PSES_BUNDLE_PATH .. "/PowerShellEditorServices/Start-EditorServices.ps1",
    "-BundledModulesPath",	PSES_BUNDLE_PATH,
    "-LogPath", session_path .. "/logs.log",
    "-SessionDetailsPath", session_file,
    "-HostName", "Neovim",
    "-HostProfileId", "Neovim.DAP",
    "-HostVersion", "1.0.0",
    "-LogLevel", "Verbose",
    "-DebugServicePipeName", pipe_name,
    "-DebugServiceOnly",
    "-EnableConsoleRepl",
  }

  local shell_cmd = table.concat(command," ")

  local current_win = vim.api.nvim_get_current_win()
  local filePath = vim.fn.expand("%:p")

  local target_height = vim.o.lines * 0.3
  vim.cmd('new')
  vim.cmd('resize ' .. target_height)

  local jobid = vim.fn.termopen(shell_cmd)
  vim.api.nvim_set_current_win(current_win)
  
  vim.g.ps_terminal_jobid = jobid

 local function onFileCreate()
    -- vim.api.nvim_del_augroup_by_name("WaitForSessionFile") -- Clean up the autocmd once triggered
    print("Session file is available. Proceeding...")
    -- Your code to handle the file creation, e.g., start a debug session
    local dap_config = {
      name = "Attach to PowerShell Process",
      type = "ps1",
      request = "launch",
      script = "${file}",
    }

    local dap = require('dap')

    dap.adapters.ps1 = {
				type = "pipe",
				pipe = "//./pipe/" .. pipe_name,
    }

    dap.run(dap_config)

    -- require('dap').continue()

    -- local command = "'" .. filePath .. "'\r"
    -- vim.fn.chansend(jobid,command)

  end

  vim.defer_fn(onFileCreate, 2000)

end

M.terminatePsDebug = function()
  local function close_terminal_by_jobid(target_jobid)
    -- Iterate through all buffers
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      -- Check if the buffer is a terminal
      if vim.bo[bufnr].buftype == 'terminal' then
        -- Get the job ID associated with the terminal buffer
        local jobid = vim.b[bufnr].terminal_job_id
        -- Check if this is the target job ID
        if jobid == target_jobid then
          -- Close the buffer (substitute with your preferred method)
          vim.api.nvim_buf_delete(bufnr, {force = true})
          -- Break out of the loop if the target buffer is found and closed
          break
        end
      end
    end
  end
  close_terminal_by_jobid(vim.g.ps_terminal_jobid)
end

return M
