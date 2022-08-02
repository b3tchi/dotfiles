lua >> EOF

--Scripting
-- !!moved to bash.vim -- BASH
-- !!moved to language file -- PowerShell

-- Presenting Languages
 -- CSS
require'lspconfig'.cssls.setup{
  capabilities = lsp_capabilities,
 }

 -- HTML
require'lspconfig'.html.setup{
  capabilities = lsp_capabilities,
}

 -- SVELTE
require'lspconfig'.svelte.setup{
  capabilities = lsp_capabilities,
}

-- Data Language
-- !!moved to yaml.vim -- YAML
require'lspconfig'.jsonls.setup{
  capabilities = lsp_capabilities,
} -- JSOM
--?? -- XML
--?? -- SQL

-- Infrastructure Languages
--require'lspconfig'.dockerls.setup{} -- DOCKER
--!!moved to language file --TERRAFORM

-- Neovim
--require'lspconfig'.sumneko_lua.setup{} --LUA
require'lspconfig'.vimls.setup{
  capabilities = lsp_capabilities,
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

EOF
