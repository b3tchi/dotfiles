Plug 'williamboman/mason.nvim'
Plug 'williamboman/mason-lspconfig.nvim'
Plug 'neovim/nvim-lspconfig'

function LoadedMason()

lua << EOF

  local status, mason = pcall(require, "mason")
  if (not status) then return end

  local status2, lspconfig = pcall(require, "mason-lspconfig")
  if (not status2) then return end

  mason.setup({
  })

  lspconfig.setup {
    ensure_installed = { "sumneko_lua", "tailwindcss" },
  }

EOF

endfunction

augroup LoadedMason
  autocmd!
  autocmd User PlugLoaded call LoadedMason()
augroup END
