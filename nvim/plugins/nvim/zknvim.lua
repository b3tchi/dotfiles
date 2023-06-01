local Plug = vim.fn['plug#']

Plug 'mickael-menu/zk-nvim'

function Load_zk()

    -- require("zk").setup()
    require("zk").setup({
    --     -- can be "telescope", "fzf" or "select" (`vim.ui.select`)
    --     -- it's recommended to use "telescope" or "fzf"
        picker = "telescope",
    --
        lsp = {
    --      -- `config` is passed to `vim.lsp.start_client(config)`
            config = {
                cmd = { "zk", "lsp" },
                name = "zk",
                on_attach = vim.g.on_attach_default,
                -- etc, see `:h vim.lsp.start_client()`
            },
    --
    --         -- automatically attach buffers in a zk notebook that match the given filetypes
            auto_attach = {
                enabled = true,
                filetypes = { "markdown" },
            },
        },
    })

end

-- local augr_plugin = vim.api.nvim_create_augroup('AutoGroup_hicolors',{clear = true})

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'
        ,group= vim.api.nvim_create_augroup('Load_zk',{clear = true})
        ,callback=Load_zk
    }
)

