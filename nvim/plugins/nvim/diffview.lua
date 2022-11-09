-- "notes taking - IN Testing
local Plug = vim.fn['plug#']

Plug 'nvim-lua/plenary.nvim'
Plug 'sindrets/diffview.nvim'


function Load_diffview()

    require('diffview').setup()

    vim.keymap.set('n', '<space>bgh', '<Cmd>DiffviewFileHistory %<CR>', {silent = true, desc='buffer git history'})

end

local augr_plugin = vim.api.nvim_create_augroup('AutoGroup_diffview',{clear = true})

vim.api.nvim_create_autocmd(
    {'User'}
    ,{pattern = 'PlugLoaded',group= augr_plugin, callback=Load_diffview}
)

