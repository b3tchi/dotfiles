"LSP Installed via coc.nvim
let g:coc_global_extensions += ['coc-powershell']

"DAP no debug yet for

lua << EOF
-- PowerShell
require('lspconfig').powershell_es.setup{
--parameter 1
capabilities = require('cmp_nvim_lsp').update_capabilities(vim.lsp.protocol.make_client_capabilities()),
--parameter 2
on_attach = on_attach_default ,
--parameter 3
--bundle_path = '/home/jan/.local/bin/powershell_es',
bundle_path = '/home/jan/.config/coc/extensions/node_modules/coc-powershell/PowerShellEditorServices',
--bundle_path = '/home/jan/repos/install-pses/PowerShellEditorServices',
--cmd = {'pwsh', '-NoLogo', '-NoProfile', '-Command', "/home/jan/.local/bin/powershell_es/PowerShellEditorServices/Start-EditorServices.ps1"},
}

EOF

