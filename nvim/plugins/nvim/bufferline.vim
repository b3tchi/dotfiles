Plug 'kyazdani42/nvim-web-devicons' " Recommended (for coloured icons)
Plug 'akinsho/bufferline.nvim', { 'tag': 'v2.*' }

echom 'file loaded buffer'
set termguicolors

function! LoadedBufferline()
echom 'func loaded buffer'
lua << EOF

-- vim.opt.termguicolors = true

require('bufferline').setup {
  options = {
    offsets = {
      {filetype = "neo-tree", text = "File Explorer" , text_align = "center"},
      {filetype = "dbui", text = "Db Explorer" , text_align = "center"},
      {filetype = "Outline", text = "Outline" , text_align = "center"},
      -- {filetype = "coc-explorer", text = "File Explorer" , text_align = "center"}, REMOVED
    },
  },
}

EOF
endfunction

augroup LoadedBufferline
  autocmd!
  autocmd User PlugLoaded call LoadedBufferline()
augroup END


