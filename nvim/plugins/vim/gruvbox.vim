Plug 'morhetz/gruvbox'

set termguicolors
set background=dark
let g:gruvbox_italic=1

hi Folded guibg=#232323

function LoadedGruvbox()
  colorscheme gruvbox

  "add event handling for selected pane
  hi ActiveWindow guibg=none
  hi InactiveWindow guibg=#32302f

  augroup WindowManagement
    autocmd!
    autocmd WinEnter * call Handle_Win_Enter()
  augroup END

  function! Handle_Win_Enter()
    setlocal winhighlight=Normal:ActiveWindow,NormalNC:InactiveWindow
  endfunction

  "by default set backgroud from based on terminal (tmux) bg color
  hi Normal ctermfg=223 ctermbg=none guifg=#ebdbb2 guibg=none

endfunction

augroup LoadedGruvbox
  autocmd!
  autocmd User PlugLoaded call LoadedGruvbox()
augroup END


