Plug 'petertriho/nvim-scrollbar'
Plug 'kevinhwang91/nvim-hlslens'

function LoadedScrollBar()
lua << EOF
require("scrollbar").setup()
require("scrollbar.handlers.search").setup()
EOF
endfunction

augroup LoadedScrollBar
  autocmd!
  autocmd User PlugLoaded call LoadedScrollBar()
augroup END
