Plug 'morhetz/gruvbox'

set termguicolors
set background=dark
let g:gruvbox_italic=1
highlight Folded guibg=#232323

" echom "plugfile"

function LoadedGruvbox()
  " echom "gruvRun"
  colorscheme gruvbox
endfunction

augroup LoadedGruvbox
  autocmd!
  autocmd User PlugLoaded call LoadedGruvbox()
augroup END
