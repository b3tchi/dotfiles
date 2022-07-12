Plug 'morhetz/gruvbox'

set termguicolors
set background=dark
let g:gruvbox_italic=1

hi Folded guibg=#232323

function LoadedGruvbox()
  colorscheme gruvbox
endfunction

augroup LoadedGruvbox
  autocmd!
  autocmd User PlugLoaded call LoadedGruvbox()
augroup END


