lua << EOF

local status, nvim_lsp = pcall(require, "lspconfig")
if (not status) then return end

local protocol = require('vim.lsp.protocol')

local on_attach = function(client, bufnr)
  -- format on save

  -- calling default functions from lualsp.vim
  on_attach_default(client, bufnr)

  if client.server_capabilities.documentFormattingProvider then
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = vim.api.nvim_create_augroup("Format", { clear = true }),
      buffer = bufnr,
      callback = function() vim.lsp.buf.formatting_seq_sync() end
    })
  end

end


require('lspconfig').tsserver.setup{
  on_attach = on_attach,
  filetypes = { "typescript", "typescriptreact", "typescript.tsx" },
  cmd = { "typescript-language-server", "--stdio" }
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

