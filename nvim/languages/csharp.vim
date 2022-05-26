"C#,VB.NET
lua << EOF

--LSP Installed via nvim-lsp-installer
--:LspInstall omnisharp
local pid = vim.fn.getpid()
--Path to coc-omnisharp
local omnisharp_bin = "/home/jan/.local/share/nvim/lsp_servers/omnisharp/omnisharp/run"

require('lspconfig').omnisharp.setup{
  --parameter 1
  capabilities = require('cmp_nvim_lsp').update_capabilities(vim.lsp.protocol.make_client_capabilities()),
  --parameter 2
  on_attach = on_attach_default ,
  --parameter 3
  cmd = { omnisharp_bin , "--languageserver" , "--hostPID" , tostring(pid) }
}

--DAP ADAPTER
--:DIInstall dnetcs
require('dap').adapters.netcoredbg = {
  type = "executable",
  command = os.getenv('HOME').. "/.local/share/nvim/dapinstall/dnetcs/netcoredbg/netcoredbg",
  args = {
    "--interpreter=vscode",
    string.format("--engineLogging=%s/netcoredbg.engine.log", XDG_CACHE_HOME),
    string.format("--log=%s/netcoredbg.log", XDG_CACHE_HOME),
  },
}

require('dap').configurations.cs = {
  {
    type = "netcoredbg",
    name = "launch - netcoredbg",
    request = "launch",
    program = function()
      local dll = io.popen("find bin/Debug/ -maxdepth 2 -name \"*.dll\"")
      return pwd() .. "/" .. dll:lines()()
    end,
    stopAtEntry = false,
    -- console = "externalTerminal",
    console = "integratedTerminal",
  },
  {
    type = "netcoredbg",
    name = "attach - netcoredbg",
    request = "attach",
    processId = 171399,
    -- processId = require'dap.utils'.pick_process,
    -- program = function()
    --   local dll = io.popen("find bin/Debug/ -maxdepth 2 -name \"*.dll\"")
    --   return pwd() .. "/" .. dll:lines()()
    -- end,
    -- stopAtEntry = false,
  },
}

-- function _G.testfx()
--   print 'abc'
-- end
-- if not foo then
function _G.mdblock_csharp(mdblock)
  --Prepare Folder
  local fname = vim.fn.FolderTemp() .. vim.fn.strftime("%Y%m%d_%H%M%S")
  vim.fn.mkdir(fname,'p')
  --Create Project
  os.execute("dotnet new console -o '" .. fname .. "' -f net6.0 --force")
  --Replace default file
  local unx_tmpps = fname .. '/Program.cs'
  vim.fn.delete(unx_tmpps)
  -- vim.fn.writefile(vim.b.mdcode,unx_tmpps)
  vim.fn.writefile(mdblock,unx_tmpps)
  --Run Command
  local cmd = "dotnet run --project '" .. fname .. "'"
  vim.fn.VimuxRunCommand(cmd)
end


EOF
