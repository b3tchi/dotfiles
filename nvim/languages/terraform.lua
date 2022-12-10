-- "LSP Installed via nvim-lsp-installer
-- " using newer version terraform-ls there is one more version terraform-lsp not officially supported
-- " :LSPInstall terraformls
--
-- Terraform-ls
require 'lspconfig'.terraformls.setup {
    on_attach = vim.g.on_attach_default,
    capabilities = vim.g.lsp_capabilities,

}

