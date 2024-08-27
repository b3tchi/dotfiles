local Plug = vim.fn['plug#']

Plug 'simrat39/symbols-outline.nvim'

function Load_symbolsoutline()

    --WHICH KEY
    require("symbols-outline").setup()

    -- vim.keymap.set('n', '<space>bgh', '<Cmd>DiffviewFileHistory %<CR>', {silent = true, desc='buffer git history'})

end


vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'
        ,group= vim.api.nvim_create_augroup('Load_symbolsoutline',{clear = true})
        ,callback=Load_symbolsoutline
    }
)

