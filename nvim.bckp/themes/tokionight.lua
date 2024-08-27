local Plug = vim.fn['plug#']
Plug ('folke/tokyonight.nvim', {branch ='main'})

function Load_theme_tokio()
    vim.cmd [[colorscheme tokyonight-night]]

    vim.api.nvim_set_hl(0, 'Folded', { bg = '#222436' }) --fold-ufo
    vim.api.nvim_set_hl(0, 'ActiveWindow', { bg = '' })
    vim.api.nvim_set_hl(0, 'InactiveWindow', { bg = '#222436' })
    vim.api.nvim_set_hl(0, 'Normal', { fg = '#7aa2f7' })
    vim.api.nvim_set_hl(0, 'DiffViewDiffAddAsDelete',{bg='#37222c'})

    vim.api.nvim_set_hl(0, 'SignColumnSB', { bg = '#1a1b26' })
    vim.api.nvim_set_hl(0, 'SignColumn', { bg = '#1a1b26' })

    vim.api.nvim_set_hl(0, 'CursorLineNr', {fg = '#ff9e64', bg = '#1a1b26' })
    vim.api.nvim_set_hl(0, 'LineNr', { fg ='#3b4261', bg = '#1a1b26' })

    vim.api.nvim_set_hl(0, 'GitSignsAdd', {fg = '#266d6a', bg = '#1a1b26' })
    vim.api.nvim_set_hl(0, 'GitSignsChange', {fg = '#536c9e', bg = '#1a1b26' })
    vim.api.nvim_set_hl(0, 'GitSignsDelete', {fg = '#b2555b', bg = '#1a1b26' })

    vim.api.nvim_set_hl(0, 'DiagnosticSignWarn', {fg = '#e0af68', bg = '#1a1b26' })
    vim.api.nvim_set_hl(0, 'DiagnosticSignInfo', {fg = '#0db9d7', bg = '#1a1b26' })
    vim.api.nvim_set_hl(0, 'DiagnosticSignHint', {fg = '#1abc9c', bg = '#1a1b26' })
    vim.api.nvim_set_hl(0, 'DiagnosticSignError', {fg = '#db4b4b', bg = '#1a1b26' })

    vim.api.nvim_set_hl(0, 'CodeBlock', { bg = '#222436' })
    -- vim.api.nvim_set_hl(0, 'Headline1', { fg = '#ff9e64', bg = '#965027' })

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

