Plug 'lifepillar/vim-solarized8'

set termguicolors
set background=dark

autocmd User PlugLoaded call s:LoadedGruvbox()

function! s:LoadedGruvbox()
  colorscheme solarized8
endfunc
