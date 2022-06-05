lua << EOF

-- LSP Installed via nvim-lsp-installer
-- :LspInstall tsserver
require'lspconfig'.tsserver.setup{
}

-- DAP should be working could Installed via dap installer line bellow
-- :DIInstall jsnode
local dap = require "dap"

-- path of where dap is installed
-- ~/.local/share/nvim/dapinstall/jsnode/vscode-node-debug2/gulpfile.js

dap.adapters.node2 = {
  type = 'executable',
  command = 'node',
  args = {
    vim.fn.stdpath("data") .. "/dapinstall/jsnode_dbg/" .. '/vscode-node-debug2/out/src/nodeDebug.js'
  }
}

dap.configurations.javascript = {
  {
    type = 'node2',
    request = 'launch',
    program = '${workspaceFolder}/${file}',
    cwd = vim.fn.getcwd(),
    sourceMaps = true,
    protocol = 'inspector',
    console = 'integratedTerminal'
  }
}

-- Markdown Evaluation
-- function _G.mdblock_bash(mdblock)
--       local lines = vim.fn.join(mdblock, '\n') ..'\n'
--       vim.fn.VimuxRunCommand(lines)
--
-- end

EOF

