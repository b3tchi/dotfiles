
function LoadedTelescope()
  " echom "gruvRun"
  " colorscheme gruvbox
  " nnoremap <silent> <space>ff :Telescope <cr> TBD
  nnoremap <silent> <space>ff :Rg<cr>
  nnoremap <silent> <space>fc :Telescope grep_string searches=<C-r><C-w><cr>
endfunction

augroup LoadedTelescope
  autocmd!
  autocmd User PlugLoaded call LoadedTelescope()
augroup END
