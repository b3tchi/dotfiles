"LSP Installed via coc.nvim
let g:coc_global_extensions += ['coc-powershell']

"DAP no debug yet for

" --- PowerShell specific ---
" powershell 200831 not regnized set manually
au! BufNewFile,BufRead *.ps1 set ft=ps1

lua << EOF
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

function _G.mdblock_pwsh(mdblock)
  --Prepare Folder
  local fname = vim.fn.FolderTemp() .. vim.fn.strftime("%Y%m%d_%H%M%S") .. '.ps1'
  --Replace default file
  local unx_tmpps = fname
  vim.fn.writefile(mdblock,unx_tmpps)
  --Run Command
  local cmd = "pwsh '" .. unx_tmpps .. "'"
  vim.fn.VimuxRunCommand(cmd)
end

-- function _G.mdblock_powershell(mdblock)
--       --Prepare Folder
--       local fname = vim.fn.FolderTemp() .. vim.fn.strftime("%Y%m%d_%H%M%S") .. '.ps1'
--       -- vim.fn.mkdir(fname,'p')
--       --Create Project
--       -- os.execute("dotnet new console -o '" .. fname .. "' -f net6.0 --force")
--       --Replace default file
--       local unx_tmpps = fname
--       -- vim.fn.delete(unx_tmpps)
--       vim.fn.writefile(mdblock,unx_tmpps)
--       --Run Command
--       local cmd = "pwsh '" .. unx_tmpps .. "'"
--       vim.fn.VimuxRunCommand(cmd)
-- end

EOF

