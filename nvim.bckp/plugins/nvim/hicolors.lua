local Plug = vim.fn['plug#']

Plug 'brenoprata10/nvim-highlight-colors'


function Load_hicolors()

    require("nvim-highlight-colors").setup {
        render = 'background',
        -- render = 'foreground',
        -- render = 'first_column',
        enable_named_colors = true,
        enable_tailwind = false
    }

end

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'
        ,group= vim.api.nvim_create_augroup('Load_hicolors',{clear = true})
        ,callback=Load_hicolors
    }
)

