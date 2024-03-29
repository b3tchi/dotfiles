Plug 'neovim/nvim-lspconfig' "offical NeoVim LSP plugin
Plug 'SmiteshP/nvim-navic'
Plug 'glepnir/lspsaga.nvim', { 'branch': 'main' }
function LuaLspLoaded()


lua << EOF
--"load pyright config
  local status_navic, navic = pcall(require, "nvim-navic")
  local status_saga, saga = pcall(require, "lspsaga")

  --Saga setup
  saga.setup({
  preview = {
      lines_above = 0,
      lines_below = 10,
      },
  scroll_preview = {
      scroll_down = "<C-f>",
      scroll_up = "<C-b>",
      },
  request_timeout = 2000,
  })

  --navic
  navic.setup {
    icons = {
      File          = " ",
      Module        = " ",
      Namespace     = " ",
      Package       = " ",
      Class         = " ",
      Method        = " ",
      Property      = " ",
      Field         = " ",
      Constructor   = " ",
      Enum          = "練",
      Interface     = "練",
      Function      = " ",
      Variable      = " ",
      Constant      = " ",
      String        = " ",
      Number        = " ",
      Boolean       = "◩ ",
      Array         = " ",
      Object        = " ",
      Key           = " ",
      Null          = "ﳠ ",
      EnumMember    = " ",
      Struct        = " ",
      Event         = " ",
      Operator      = " ",
      TypeParameter = " ",
    },
    highlight = false,
    separator = " > ",
    depth_limit = 0,
    depth_limit_indicator = "..",
  }


-- diagnostics symbols
vim.diagnostic.config({
  virtual_text = true,
  signs = true,
  underline = true,
  update_in_insert = false,
  severity_sort = false,
})

local signs = { Error = "", Warn = "", Hint = "", Info = "" }
for type, icon in pairs(signs) do
  local hl = "DiagnosticSign" .. type
  vim.fn.sign_define(hl, { text = icon, texthl = hl, numhl = hl })
end

-- Use an on_attach_default function to only map the following keys
-- after the language server attaches to the current buffer
_G.on_attach_default = function(client, bufnr)

  if client.server_capabilities.documentSymbolProvider then
    navic.attach(client, bufnr)
  end

  local function buf_set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
  local function buf_set_option(...) vim.api.nvim_buf_set_option(bufnr, ...) end


  -- Enable completion triggered by <c-x><c-o>
  buf_set_option('omnifunc', 'v:lua.vim.lsp.omnifunc')

  -- Mappings.
  local opts = { noremap=true, silent=true }

  --need to found another shortcut this is needed for navigation
  -- vim.keymap.set('n', '<C-j>', '<Cmd>Lspsaga diagnostic_jump_next<CR>', opts)
  vim.keymap.set('i', '<C-k>', '<Cmd>Lspsaga signature_help<CR>', opts)

  vim.keymap.set('n', 'gp', '<Cmd>Lspsaga preview_definition<CR>', opts)


  -- See `:help vim.lsp.*` for documentation on any of the below functions

  buf_set_keymap('n', 'gD', '<cmd>lua vim.lsp.buf.declaration()<CR>', opts)
  -- buf_set_keymap('n', 'gd', '<cmd>lua vim.lsp.buf.definition()<CR>', opts)
  buf_set_keymap('n', 'gd', '<Cmd>Lspsaga lsp_finder<CR>', opts)
  -- buf_set_keymap('n', 'K', '<cmd>lua vim.lsp.buf.hover()<CR>', opts)
  buf_set_keymap('n', 'K', '<Cmd>Lspsaga hover_doc<CR>', opts)
  buf_set_keymap('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<CR>', opts)
  buf_set_keymap('n', '<space>wa', '<cmd>lua vim.lsp.buf.add_workspace_folder()<CR>', opts)
  buf_set_keymap('n', '<space>wr', '<cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>', opts)
  buf_set_keymap('n', '<space>wl', '<cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>', opts)
  buf_set_keymap('n', '<space>D', '<cmd>lua vim.lsp.buf.type_definition()<CR>', opts)
  -- buf_set_keymap('n', '<space>rn', '<cmd>lua vim.lsp.buf.rename()<CR>', opts)
  buf_set_keymap('n', '<space>rn', '<Cmd>Lspsaga rename<CR>', opts)

 buf_set_keymap('n', '<space>vca', '<cmd>lua vim.lsp.buf.code_action()<CR>', opts)
  buf_set_keymap('n', 'gr', '<cmd>lua vim.lsp.buf.references()<CR>', opts)
  buf_set_keymap('n', '[d', '<cmd>lua vim.lsp.diagnostic.goto_prev()<CR>', opts)
  buf_set_keymap('n', ']d', '<cmd>lua vim.lsp.diagnostic.goto_next()<CR>', opts)
  buf_set_keymap('n', '<space>q', '<cmd>lua vim.lsp.diagnostic.set_loclist()<CR>', opts)
  -- buf_set_keymap('n', 'bd', '<cmd>lua require('telescope.builtin').builtin.lsp_document_symbols()<CR>', opts)
  -- buf_set_keymap('n', '<C-k>', '<cmd>lua vim.lsp.buf.signature_help()<CR>', opts)
  -- buf_set_keymap('n', '<space>e', '<cmd>lua vim.lsp.diagnostic.show_line_diagnostics()<CR>', opts)
  -- buf_set_keymap('n', '<space>f', '<cmd>lua vim.lsp.buf.formatting()<CR>', opts)
  -- print('loaded' .. 'client')

end

vim.g.on_attach_default=_G.on_attach_default
--Starting Lsp Config details
local nvim_lsp = require('lspconfig')

--moved to cmp overwritten by lsp
_G.lsp_capabilities = vim.lsp.protocol.make_client_capabilities()
vim.g.lsp_capabilities = _G.lsp_capabilities

EOF
endfunction

augroup LuaLspLoaded
  autocmd!
  autocmd User PlugLoaded call LuaLspLoaded()
augroup END
