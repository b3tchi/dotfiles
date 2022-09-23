Plug 'williamboman/mason.nvim'
Plug 'williamboman/mason-lspconfig.nvim'
Plug 'neovim/nvim-lspconfig'

function LoadedMason()

lua << EOF
  require("mason").setup()
  require("mason-lspconfig").setup()
EOF

endfunction

augroup LoadedMason
  autocmd!
  autocmd User PlugLoaded call LoadedMason()
augroup END
