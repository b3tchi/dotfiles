
lua << EOF
--"load pyright config

-- Use an on_attach_default function to only map the following keys
-- after the language server attaches to the current buffer
_G.on_attach_default = function(client, bufnr)
  local function buf_set_keymap(...) vim.api.nvim_buf_set_keymap(bufnr, ...) end
  local function buf_set_option(...) vim.api.nvim_buf_set_option(bufnr, ...) end

  -- Enable completion triggered by <c-x><c-o>
  buf_set_option('omnifunc', 'v:lua.vim.lsp.omnifunc')

  -- Mappings.
  local opts = { noremap=true, silent=true }

  -- See `:help vim.lsp.*` for documentation on any of the below functions
  buf_set_keymap('n', 'gD', '<cmd>lua vim.lsp.buf.declaration()<CR>', opts)
  buf_set_keymap('n', 'gd', '<cmd>lua vim.lsp.buf.definition()<CR>', opts)
  buf_set_keymap('n', 'K', '<cmd>lua vim.lsp.buf.hover()<CR>', opts)
  buf_set_keymap('n', 'gi', '<cmd>lua vim.lsp.buf.implementation()<CR>', opts)
  buf_set_keymap('n', '<space>wa', '<cmd>lua vim.lsp.buf.add_workspace_folder()<CR>', opts)
  buf_set_keymap('n', '<space>wr', '<cmd>lua vim.lsp.buf.remove_workspace_folder()<CR>', opts)
  buf_set_keymap('n', '<space>wl', '<cmd>lua print(vim.inspect(vim.lsp.buf.list_workspace_folders()))<CR>', opts)
  buf_set_keymap('n', '<space>D', '<cmd>lua vim.lsp.buf.type_definition()<CR>', opts)
  buf_set_keymap('n', '<space>rn', '<cmd>lua vim.lsp.buf.rename()<CR>', opts)
  buf_set_keymap('n', '<space>vca', '<cmd>lua vim.lsp.buf.code_action()<CR>', opts)
  buf_set_keymap('n', 'gr', '<cmd>lua vim.lsp.buf.references()<CR>', opts)
  buf_set_keymap('n', '[d', '<cmd>lua vim.lsp.diagnostic.goto_prev()<CR>', opts)
  buf_set_keymap('n', ']d', '<cmd>lua vim.lsp.diagnostic.goto_next()<CR>', opts)
  buf_set_keymap('n', '<space>q', '<cmd>lua vim.lsp.diagnostic.set_loclist()<CR>', opts)
  -- buf_set_keymap('n', '<space>O', '<cmd>lua require('telescope.builtin').builtin.lsp_document_symbols()<CR>', opts)
  -- buf_set_keymap('n', '<C-k>', '<cmd>lua vim.lsp.buf.signature_help()<CR>', opts)
  -- buf_set_keymap('n', '<space>e', '<cmd>lua vim.lsp.diagnostic.show_line_diagnostics()<CR>', opts)
  -- buf_set_keymap('n', '<space>f', '<cmd>lua vim.lsp.buf.formatting()<CR>', opts)
  -- print('loaded' .. client)

end

--Scripting
-- !!moved to bash.vim -- BASH
-- !!moved to language file -- PowerShell

-- Presenting Languages
 -- CSS
require'lspconfig'.cssls.setup{
  capabilities = ufo_capabilities,
 }

 -- HTML
require'lspconfig'.html.setup{
  capabilities = ufo_capabilities,
}

 -- SVELTE
require'lspconfig'.svelte.setup{
  capabilities = ufo_capabilities,
}

-- Data Language
-- !!moved to yaml.vim -- YAML
require'lspconfig'.jsonls.setup{
  capabilities = ufo_capabilities,
} -- JSOM
--?? -- XML
--?? -- SQL

-- Infrastructure Languages
--require'lspconfig'.dockerls.setup{} -- DOCKER
--!!moved to language file --TERRAFORM

-- Neovim
--require'lspconfig'.sumneko_lua.setup{} --LUA
require'lspconfig'.vimls.setup{
  capabilities = ufo_capabilities,
} -- VIML

-- Documentation
require'lspconfig'.remark_ls.setup{} -- MARKDOWN

-- General purpose
--?? --GO
-- path of where dap is installed
--!!moved to language file --TYPESCRIPT
--!!moved to language file --JAVASCRIPT
--require'lspconfig'.rust_analyzer.setup{} --RUST
--require'lspconfig'.ccls.setup{} --C
--!!moved to language file --C#,VB.NET
require'lspconfig'.pyright.setup{} -- PYTHON


--Starting Lsp Config details
local nvim_lsp = require('lspconfig')

-- Use a loop to conveniently call 'setup' on multiple servers and
-- map buffer local keybindings when the language server attaches
local servers = { 'pyright', 'vimls' }
for _, lsp in ipairs(servers) do
  nvim_lsp[lsp].setup {
    on_attach = on_attach_default,
    flags = {
      debounce_text_changes = 150,
    }
  }
end

--TREESITTER
require'nvim-treesitter.configs'.setup {
  ensure_installed = "all", -- one of "all", "maintained" (parsers with maintainers), or a list of languages
  ignore_install = { "javascript" }, -- List of parsers to ignore installing
  highlight = {
    enable = true,              -- false will disable the whole extension
    -- disable = { "c", "rust" },  -- list of language that will be disabled
    -- Setting this to true will run `:h syntax` and tree-sitter at the same time.
    -- Set this to `true` if you depend on 'syntax' being enabled (like for indentation).
    -- Using this option may slow down your editor, and you may see some duplicate highlights.
    -- Instead of true it can also be a list of languages
    additional_vim_regex_highlighting = false,
  },
}

--Telescope
-- You dont need to set any of these options. These are the default ones. Only
-- the loading is important
require('telescope').setup {
  extensions = {
    fzf = {
      fuzzy = true,                    -- false will only do exact matching
      override_generic_sorter = true,  -- override the generic sorter
      override_file_sorter = true,     -- override the file sorter
      case_mode = "smart_case",        -- or "ignore_case" or "respect_case"
      -- the default case_mode is "smart_case"
      }
  }
}

require("telescope").load_extension("git_worktree")
require("telescope").load_extension("fzf")

-- To get fzf loaded and working with telescope, you need to call
-- load_extension, somewhere after setup function:

--CMP - AUTOCOMPLETIONS
local cmp = require 'cmp'
cmp.setup {
  mapping = {
    ['<Tab>'] = cmp.mapping.select_next_item(),
    ['<S-Tab>'] = cmp.mapping.select_prev_item(),
    ['<CR>'] = cmp.mapping.confirm({
      behavior = cmp.ConfirmBehavior.Replace,
      select = true,
    })
  },
  sources = {
    { name = 'nvim_lsp' },
  }
}

--INDENT GUIDES
require("indent_blankline").setup {
  -- for example, context is off by default, use this to turn it on
  show_current_context = true,
  show_current_context_start = true,
  buftype_exclude = {
    "teminal"
  },
  filetype_exclude = {
    "coc-explorer"
    ,"help"
    ,"neo-tree"
    ,"netrw"
    ,"startify"
    ,"which_key"
    ,"vim-plug"
    ,"dbout"
  }

}

--COMMENTS
require("Comment").setup()

--WHICH KEY
local wk = require("which-key")

wk.setup {
  plugins = {
    spelling = {
    enabled = true, -- enabling this will show WhichKey when pressing z= to select spelling suggestions
    suggestions = 20, -- how many suggestions should be shown in the list?
    },
  },
}


function recursemap(mapl, xpath)
  -- print(mapl)
  -- for key in keys(vim.g.which_key_map)
  for key,value in pairs(mapl) do --actualcode
    -- myTable[key] = "foobar"
    -- print(type(value))
    if type(value) == "table" then
      --print(xpath .. key)
      --print(mapl[key]["name"])
      recursemap(value, xpath .. key)
      wk.register({ [xpath .. key] = {mapl[key]["name"]}, })
    else
      -- print(key)
      if key ~= "name" then
        --print(xpath .. key)
        --print(mapl[key])
        wk.register({ [xpath .. key] = {mapl[key]}, })
      end
    end
  end

end

recursemap(vim.g.which_key_map,'<space>')
wk.register({ ["<space>f"] = {"find" }, })
--
--
-- wk.register({
--   ["<space>"] = {
--     g = {
--       name = "+git",
--     },
--   },
-- })
-- method 3
--

EOF
