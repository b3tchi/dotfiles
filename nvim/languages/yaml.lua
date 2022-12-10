-- "LSP Installed via nvim-lsp-installer
-- " using newer version terraform-ls there is one more version terraform-lsp not officially supported
-- " :LSPInstall yamlls
--
-- "DAP in vimspector only not yet in nvim-Dap only in vimspector
--
-- lua << EOF
 -- YAML
 require'lspconfig'.yamlls.setup{
  on_attach = on_attach_default,
  capabilities = lsp_capabilities,
  settings = {
    yaml = {
      schemas = {
        ["https://raw.githubusercontent.com/microsoft/azure-pipelines-vscode/main/service-schema.json"]= "*/ci/pipelines/*.yml"
        -- ["https://raw.githubusercontent.com/quantumblacklabs/kedro/develop/static/jsonschema/kedro-catalog-0.17.json"]= "conf/**/*catalog*",
        -- ["https://json.schemastore.org/github-workflow.json"] = "/.github/workflows/*"
        }
      }
    }
}

-- function _G.mdblock_bash(mdblock)
--       local lines = vim.fn.join(mdblock, '\n') ..'\n'
--       vim.fn.VimuxRunCommand(lines)
--
-- end

-- EOF

