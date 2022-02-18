Plug 'morhetz/gruvbox'

set termguicolors
set background=dark
let g:gruvbox_italic=1
highlight Folded guibg=#232323

echom "plugfile"

function LoadedSolarized()
  echom "gruvRun"
  colorscheme gruvbox
endfunction

augroup LoadedSolarized
  autocmd!
  autocmd User PlugLoaded call LoadedSolarized()
augroup END
