Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-telescope/telescope-fzf-native.nvim',  { 'do': 'make' }

function LoadedTelescope()
  nnoremap <silent> <space>ff :Rg<cr>
  nnoremap <silent> <space>fc :Telescope grep_string searches=<C-r><C-w><cr>
  nnoremap <silent> <space>oo :Telescope lsp_document_symbols<cr>
endfunction

augroup LoadedTelescope
  autocmd!
  autocmd User PlugLoaded call LoadedTelescope()
augroup END
