Plug 'blueyed/vim-diminactive'



function LoadedDimInactive()

"lua << EOF
"EOF

endfunction

augroup LoadedDimInactive
  autocmd!
  autocmd User PlugLoaded call LoadedDimInactive()
augroup END
