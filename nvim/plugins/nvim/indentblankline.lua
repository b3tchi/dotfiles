local Plug = vim.fn['plug#']

Plug 'lukas-reineke/indent-blankline.nvim'

function Load_blanklines()

    require("indent_blankline").setup {
        -- for example, context is off by default, use this to turn it on
        show_current_context = true,
        show_current_context_start = true,
        buftype_exclude = {
            "teminal"
        },
        filetype_exclude = {
            "coc-explorer"
            ,"help"
            ,"neo-tree"
            ,"netrw"
            ,"startify"
            ,"which_key"
            ,"vim-plug"
            ,"dbout"
            ,"org"
        }

    }

end

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'
        ,group= vim.api.nvim_create_augroup('Load_blanklines',{clear = true})
        ,callback=Load_blanklines
    }
)

