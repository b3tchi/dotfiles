lua << EOF
-- https://github.com/neovim/nvim-lspconfig/blob/master/doc/server_configurations.md
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

require'lspconfig'.sumneko_lua.setup {
  settings = {
    Lua = {
      runtime = {
        -- Tell the language server which version of Lua you're using (most likely LuaJIT in the case of Neovim)
        version = 'LuaJIT',
      },
      diagnostics = {
        -- Get the language server to recognize the `vim` global
        globals = {'vim'},
      },
      workspace = {
        -- Make the server aware of Neovim runtime files
        library = vim.api.nvim_get_runtime_file("", true),
      },
      -- Do not send telemetry data containing a randomized but unique identifier
      telemetry = {
        enable = false,
      },
    },
  },
}

--?? -- XML
--?? -- SQL

-- Infrastructure Languages
--require'lspconfig'.dockerls.setup{} -- DOCKER
--!!moved to language file --TERRAFORM

-- Neovim
--require'lspconfig'.sumneko_lua.setup{} --LUA
require'lspconfig'.vimls.setup{
  capabilities = lsp_capabilities,
} -- VIML:wikis



-- Documentationand notetaking
require'lspconfig'.marksman.setup{
} -- MARKDOWN

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
  require'lspconfig'[lsp].setup {
    on_attach = on_attach_default,
    flags = {
      debounce_text_changes = 150,
    }
  }
end

--  vimscript
function _G.mdblock_vim(mdblock)
    local fname = tmp_file('vim')
    local tmppath = lux_temppath() .. fname

    vim.fn.writefile(mdblock, tmppath)
    vim.api.nvim_command('source ' .. tmppath)
    vim.fn.delete(tmp)

end

--  lua
function _G.mdblock_lua(mdblock)

    local fname = tmp_file('lua')
    local tmppath = lux_temppath() .. fname

    -- print(tmppath)
    vim.fn.writefile(mdblock, tmppath)
    vim.api.nvim_command('source ' .. tmppath)
    vim.fn.delete(tmp)

end

EOF
