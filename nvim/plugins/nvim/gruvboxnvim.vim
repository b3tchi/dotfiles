Plug 'ellisonleao/gruvbox.nvim'

set termguicolors
set background=dark

function LoadedGruvboxNvim()

lua << EOF
require("gruvbox").setup({
  undercurl = true,
  underline = true,
  bold = true,
  italic = true,
  strikethrough = true,
  invert_selection = false,
  invert_signs = false,
  invert_tabline = true,
  invert_intend_guides = false,
  inverse = true, -- invert background for search, diffs, statuslines and errors
  contrast = "", -- can be "hard", "soft" or empty string
  overrides = {},
})
  -- vim.cmd("colorscheme gruvbox")
EOF
  colorscheme gruvbox

  hi Folded guibg=#232323

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

augroup LoadedGruvboxNvim
  autocmd!
  autocmd User PlugLoaded call LoadedGruvboxNvim()
augroup END
