local Plug = vim.fn['plug#']
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'kyazdani42/nvim-web-devicons'
Plug 'pwntester/octo.nvim'
-- Plug 'lewis6991/gitsigns.nvim'

function Load_Octo()
    --git markers
    require('octo').setup({
		ssh_aliases = {
			["github.com-jan-becka"] = "github.com",
			["github.com-b3tchi"] = "github.com",
		},
    })

    -- vim.keymap.set('n', '<space>gb', '<Cmd>Gitsigns toggle_current_line_blame<CR>', {silent = true, desc='current git hunk'})
end

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'

        ,group= vim.api.nvim_create_augroup('Load_Octo',{clear = true})
        ,callback=Load_Octo
    }
)
