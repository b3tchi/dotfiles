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
EOF
