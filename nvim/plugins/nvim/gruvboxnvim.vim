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
vim.cmd("colorscheme gruvbox")
EOF

endfunction

augroup LoadedGruvboxNvim
  autocmd!
  autocmd User PlugLoaded call LoadedGruvboxNvim()
augroup END
