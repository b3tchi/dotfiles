local Plug = vim.fn['plug#']
Plug 'kyazdani42/nvim-web-devicons'
Plug 'folke/trouble.nvim'

function Load_trouble()

    require("trouble").setup({
    })

end

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'
        ,group= vim.api.nvim_create_augroup('Load_trouble',{clear = true})
        ,callback=Load_trouble
    }
)

