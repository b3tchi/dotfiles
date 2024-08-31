Plug 'kyazdani42/nvim-web-devicons' " optional, for file icons
Plug 'kyazdani42/nvim-tree.lua'

function LoadedNvimTree()

lua << EOF
require("nvim-tree").setup()
EOF
endfunction

augroup LoadedNvimTree
  autocmd!
  autocmd User PlugLoaded call LoadedNvimTree()
augroup END
