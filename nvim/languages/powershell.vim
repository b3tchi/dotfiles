"LSP Installed via coc.nvim

"DAP no debug yet for

" --- PowerShell specific ---
" powershell 200831 not regnized set manually
au! BufNewFile,BufRead *.ps1 set ft=ps1

lua << EOF

-- local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
-- parser_config.powershell = {
--   install_info = {
--     url = "https://github.com/jrsconfitto/tree-sitter-powershell",
--     files = {"src/parser.c"}
--   },
--   filetype = "ps1",
--   used_by = { "psm1", "psd1", "pssc", "psxml", "cdxml" }
-- }

-- PowerShell
require('lspconfig').powershell_es.setup{
  --parameter 1
  capabilities = lsp_capabilities,
  -- capabilities = require('cmp_nvim_lsp').update_capabilities(vim.lsp.protocol.make_client_capabilities()),
  --parameter 2
  on_attach = on_attach_default ,
  --parameter 3
  --bundle_path = '/home/jan/.local/bin/powershell_es',
  -- bundle_path = '/home/jan/.config/coc/extensions/node_modules/coc-powershell/PowerShellEditorServices', --coc link
  bundle_path = '/home/jan/.local/share/nvim/mason/packages/powershell-editor-services', --mason link
  --bundle_path = '/home/jan/repos/install-pses/PowerShellEditorServices',
  --cmd = {'pwsh', '-NoLogo', '-NoProfile', '-Command', "/home/jan/.local/bin/powershell_es/PowerShellEditorServices/Start-EditorServices.ps1"},
}

function _G.mdblock_powershell(mdblock)

    local winpath = win_temppath() .. tmp_file('ps1')

    vim.fn.writefile(mdblock, winpath_from_wsl(winpath))

    local cmd = "powershell.exe '" .. winpath .. "'"

    vim.fn.VimuxRunCommand(cmd)

end

function _G.mdblock_pwsh(mdblock)
  --Prepare Folder
  -- local fname = vim.fn.FolderTemp() .. vim.fn.strftime("%Y%m%d_%H%M%S") .. '.ps1'
  --Replace default file
  -- local unx_tmpps = fname

  local temp_path = lux_temppath() .. tmp_file('ps1')

  vim.fn.writefile(mdblock, temp_path)
  --Run Command
  local cmd = "pwsh '" .. unx_tmpps .. "'"
  vim.fn.VimuxRunCommand(cmd)

end

EOF

