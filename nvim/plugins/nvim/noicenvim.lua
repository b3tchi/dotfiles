local Plug = vim.fn['plug#']
    Plug 'rcarriga/nvim-notify'
    Plug 'folke/noice.nvim'
    Plug 'MunifTanjim/nui.nvim'


function Load_noice()

    require("notify").setup({
      background_colour = "#000000",
    })

    require('noice').setup()
end

vim.api.nvim_create_autocmd(
    { 'User' }, { pattern = 'PlugLoaded'
        , group = vim.api.nvim_create_augroup('Load_noice', { clear = true })
        ,callback=Load_noice
    }
)
