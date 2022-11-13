Plug 'ellisonleao/gruvbox.nvim'

" set termguicolors
" set background=dark

function LoadedGruvboxNvim()

lua << EOF

vim.opt.termguicolors = true
vim.opt.background = "dark"

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

  vim.cmd('colorscheme gruvbox')

  vim.api.nvim_set_hl(0,'Folded',{bg='#232323'})
  -- hi Folded guibg=#232323
  vim.api.nvim_set_hl(0,'ActiveWindow',{bg=''})
  -- hi ActiveWindow guibg=none
  vim.api.nvim_set_hl(0,'InactiveWindow',{bg='#32302f'})
  -- hi InactiveWindow guibg=#32302f

  --by default set backgroud from based on terminal (tmux) bg color
  vim.api.nvim_set_hl(0,'Normal',{bg='',fg='#EBDBB2'})
  -- hi Normal ctermfg=223 ctermbg=none guifg=#ebdbb2 guibg=none


    -- local augr_handle = vim.api.nvim_create_augroup('WindowManagement',{clear = true})
  function Handle_Win_Enter()
      -- print('onecommend')
      vim.cmd[[ setlocal winhighlight=Normal:ActiveWindow,NormalNC:InactiveWindow ]]
  end

    vim.api.nvim_create_autocmd(
        {'WinEnter'} ,{pattern = '*'
        ,group=vim.api.nvim_create_augroup('WindowManagement',{clear = true})--augr_handle
        ,callback=Handle_Win_Enter
        }
    )


EOF
  " colorscheme gruvbox

  " add event handling for selected pane
  " augroup WindowManagement
  "   autocmd!
  "   autocmd WinEnter * call Handle_Win_Enter()
  " augroup END
  "
  " function! Handle_Win_Enter()
  "   setlocal winhighlight=Normal:ActiveWindow,NormalNC:InactiveWindow
  " endfunction

endfunction

augroup LoadedGruvboxNvim
  autocmd!
  autocmd User PlugLoaded call LoadedGruvboxNvim()
augroup END
