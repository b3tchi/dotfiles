-- "notes taking - IN Testing
local Plug = vim.fn['plug#']

Plug ('folke/tokyonight.nvim', {branch ='main'})


function Load_theme_tokio()

    vim.cmd[[colorscheme tokyonight]]

end

local augr_plugin = vim.api.nvim_create_augroup('AutoGroup_theme_tokio',{clear = true})

vim.api.nvim_create_autocmd(
    {'User'}
    ,{pattern = 'PlugLoaded',group= augr_plugin, callback=Load_theme_tokio}
)

