-- lua << EOF
-- https://github.com/neovim/nvim-lspconfig/blob/master/doc/server_configurations.md
--Scripting
-- !!moved to bash.vim -- BASH
-- !!moved to language file -- PowerShell

-- Presenting Languages
 -- CSS
require'lspconfig'.cssls.setup{
  on_attach = vim.g.on_attach_default,
  capabilities = vim.g.lsp_capabilities,
 }

 -- HTML
require'lspconfig'.html.setup{
  on_attach = vim.g.on_attach_default,
  capabilities = vim.g.lsp_capabilities,
}

 -- SVELTE
require'lspconfig'.svelte.setup{
  on_attach = vim.g.on_attach_default,
  capabilities = vim.g.lsp_capabilities,
}

-- Data Language
-- !!moved to yaml.vim -- YAML
require'lspconfig'.jsonls.setup{
  on_attach = vim.g.on_attach_default,
  capabilities = vim.g.lsp_capabilities,
} -- JSOM

require'lspconfig'.sumneko_lua.setup {
  on_attach = vim.g.on_attach_default,
  capabilities = vim.g.lsp_capabilities,
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
--  lua
function _G.mdblock_lua(mdblock)

    local fname = vim.gtmp_file('lua')
    local tmppath = vim.g.lux_temppath() .. fname

    -- print(tmppath)
    vim.fn.writefile(mdblock, tmppath)
    vim.api.nvim_command('source ' .. tmppath)
    -- vim.fn.delete(tmp)

end

--?? -- XML
--?? -- SQL

-- Infrastructure Languages
--require'lspconfig'.dockerls.setup{} -- DOCKER
--!!moved to language file --TERRAFORM

-- Neovim
--require'lspconfig'.sumneko_lua.setup{} --LUA
require'lspconfig'.vimls.setup{
  on_attach = vim.g.on_attach_default,
  capabilities = vim.g.lsp_capabilities,
} -- VIML:wikis

--  vimscript
function _G.mdblock_vim(mdblock)
    local fname = vim.g.tmp_file('vim')
    local tmppath = vim.g.lux_temppath() .. fname

    vim.fn.writefile(mdblock, tmppath)
    vim.api.nvim_command('source ' .. tmppath)
    -- vim.fn.delete(tmp)

end


-- Documentationand notetaking
require'lspconfig'.marksman.setup{
  on_attach = vim.g.on_attach_default,
  capabilities = vim.g.lsp_capabilities,
} -- MARKDOWN

-- General purpose
--?? --GO
-- path of where dap is installed
--!!moved to language file --TYPESCRIPT
--!!moved to language file --JAVASCRIPT
--require'lspconfig'.rust_analyzer.setup{} --RUST
--require'lspconfig'.ccls.setup{} --C
--!!moved to language file --C#,VB.NET
require'lspconfig'.pyright.setup{
  on_attach = vim.g.on_attach_default,
  capabilities = vim.g.lsp_capabilities,
} -- PYTHON

-- EOF
