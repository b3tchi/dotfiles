local Plug = vim.fn['plug#']

Plug 'lewis6991/gitsigns.nvim'

function Load_gitsigns()
    --git markers
    require('gitsigns').setup()

    vim.keymap.set('n', '<space>gj', '<Cmd>Gitsigns next_hunk<CR>', {silent = true, desc='next git hunk'})
    vim.keymap.set('n', '<space>gk', '<Cmd>Gitsigns prev_hunk<CR>', {silent = true, desc='prev git hunk'})
    vim.keymap.set('n', '<space>gi', '<Cmd>Gitsigns preview_hunk<CR>', {silent = true, desc='current git hunk'})
end

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'
        ,group= vim.api.nvim_create_augroup('Load_gitsigns',{clear = true})
        ,callback=Load_gitsigns
    }
)
