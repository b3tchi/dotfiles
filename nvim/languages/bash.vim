"LSP Installed via nvim-lsp-installer
" :LSPInstall bashls
"DAP in vimspector only not yet in nvim-Dap only in vimspector

lua << EOF
-- BASH

require'lspconfig'.bashls.setup{
  on_attach = on_attach_default,
  capabilities = lsp_capabilities,
  flags = {
    debounce_text_changes = 150,
  },
}

function _G.mdblock_bash(mdblock)
  local lines = vim.fn.join(mdblock, '\n') ..'\n'
  vim.fn.VimuxRunCommand(lines)
end

EOF

function LoadedBashLang()
  autocmd FileType sh nnoremap <buffer> <space>o :Telescope lsp_document_symbols<CR>
endfunction

augroup LoadedBashLang
  autocmd!
  autocmd User PlugLoaded call LoadedBashLang()
augroup END

