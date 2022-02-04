Plug 'morhetz/gruvbox'

set termguicolors
set background=dark
let g:gruvbox_italic=1
highlight Folded guibg=#232323

echom "plugfile"

autocmd User PlugLoaded call s:LoadedSolarized()

function! s:LoadedSolarized()
  echom "plugfileRun"
  colorscheme gruvbox
endfunc

