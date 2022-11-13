-- "notes taking - IN Testing
local Plug = vim.fn['plug#']
Plug ('folke/tokyonight.nvim', {branch ='main'})

function Load_theme_tokio()
    vim.cmd[[colorscheme tokyonight-night]]
end

local augr = vim.api.nvim_create_augroup   -- Create/get autocommand group
vim.api.nvim_create_autocmd(
    {'User'} ,{pattern='PlugLoaded'
        ,group=augr('Load_theme_tokio',{clear = true})
        ,callback=Load_theme_tokio
    }
)

