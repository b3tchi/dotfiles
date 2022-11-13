local Plug = vim.fn['plug#']

Plug 'ellisonleao/gruvbox.nvim'

function Load_theme_gruvbox()

    vim.opt.termguicolors = true
    vim.opt.background = "dark"

    require("gruvbox").setup({
        undercurl = true,
        underline = true,
        bold = true,
        italic = true,
        strikethrough = true,
        invert_selection = false,
        invert_signs = false,
        invert_tabline = true,
        invert_intend_guides = false,
        inverse = true, -- invert background for search, diffs, statuslines and errors
        contrast = "", -- can be "hard", "soft" or empty string
        overrides = {},
    })

    vim.cmd('colorscheme gruvbox')

    vim.api.nvim_set_hl(0,'Folded',{bg='#232323'})
    -- hi Folded guibg=#232323
    vim.api.nvim_set_hl(0,'ActiveWindow',{bg=''})
    -- hi ActiveWindow guibg=none
    vim.api.nvim_set_hl(0,'InactiveWindow',{bg='#32302f'})
    -- hi InactiveWindow guibg=#32302f

    --by default set backgroud from based on terminal (tmux) bg color
    vim.api.nvim_set_hl(0,'Normal',{bg='',fg='#EBDBB2'})
    -- hi Normal ctermfg=223 ctermbg=none guifg=#ebdbb2 guibg=none


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
        ,group=augr('Load_theme_gruvbox',{clear = true})
        ,callback=Load_theme_gruvbox
    }
)
