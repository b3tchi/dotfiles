"--- Indent Guides ---
" let g:indent_guides_enable_on_vim_startup = 1
" let g:indent_guides_auto_colors = 0
" let g:indent_guides_color_change_percent = 3 " for auto options left 5 percent only

if g:vimmode != 3
  "color form solarized8
  if g:vimTheme == 1
    autocmd VimEnter,Colorscheme * :hi IndentGuidesOdd  guibg=#002b36 ctermbg=3
    autocmd VimEnter,Colorscheme * :hi IndentGuidesEven guibg=#073642 ctermbg=4
  elseif g:vimTheme == 2
    autocmd VimEnter,Colorscheme * :hi IndentGuidesOdd  guibg=#282828 ctermbg=3
    autocmd VimEnter,Colorscheme * :hi IndentGuidesEven  guibg=#232323 ctermbg=4
  endif
endif
