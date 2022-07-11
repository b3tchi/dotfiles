Plug 'sunjon/shade.nvim'


function LoadedShade()

lua << EOF

require'shade'.setup({
  overlay_opacity = 70,
  opacity_step = 1,
  -- keys = {
  --   brightness_up    = '<C-Up>',
  --   brightness_down  = '<C-Down>',
  --   toggle           = '<Leader>s',
  -- }
})

EOF
endfunction

augroup LoadedShade
  autocmd!
  autocmd User PlugLoaded call LoadedShade()
augroup END
