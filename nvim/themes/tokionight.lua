-- "notes taking - IN Testing
local Plug = vim.fn['plug#']
Plug ('folke/tokyonight.nvim', {branch ='main'})

function Load_theme_tokio()
    vim.cmd[[colorscheme tokyonight-night]]

    vim.api.nvim_set_hl(0,'Folded',{bg='#222436'}) --fold-ufo
    vim.api.nvim_set_hl(0,'ActiveWindow',{bg=''})
    vim.api.nvim_set_hl(0,'InactiveWindow',{bg='#222436'})
    vim.api.nvim_set_hl(0,'Normal',{fg='#7aa2f7'})
    vim.api.nvim_set_hl(0,'DiffDelete',{bg='#37222c', fg='#222436'})

    vim.cmd[[set fillchars+=diff:╱]]

    function Handle_Win_Enter()
        vim.cmd[[ setlocal winhighlight=Normal:ActiveWindow,NormalNC:InactiveWindow ]]
    end

    local augr = vim.api.nvim_create_augroup   -- Create/get autocommand group
    vim.api.nvim_create_autocmd(
        {'WinEnter'} ,{pattern='*'
            ,group=augr('WindowManagement',{clear = true})--augr_handle
            ,callback=Handle_Win_Enter
        }
    )

end

local augr = vim.api.nvim_create_augroup   -- Create/get autocommand group
vim.api.nvim_create_autocmd(
    {'User'} ,{pattern='PlugLoaded'
        ,group=augr('Load_theme_tokio',{clear = true})
        ,callback=Load_theme_tokio
    }
)

