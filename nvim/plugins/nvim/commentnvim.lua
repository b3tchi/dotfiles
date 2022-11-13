local Plug = vim.fn['plug#']

Plug 'numToStr/Comment.nvim'

function Load_commentnvim()

    require("Comment").setup()

    -- vim.keymap.set('n', '<space>bgh', '<Cmd>DiffviewFileHistory %<CR>', {silent = true, desc='buffer git history'})

end

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'
        ,group= vim.api.nvim_create_augroup('Load_commentnvim',{clear = true})
        ,callback=Load_commentnvim
    }
)

