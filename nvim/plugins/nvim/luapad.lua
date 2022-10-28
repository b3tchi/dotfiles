-- "notes taking - IN Testing
local Plug = vim.fn['plug#']

Plug 'rafcamlet/nvim-luapad'

function Load_luapad()
-- " lua << EOF

    require('luapad').setup {
        count_limit = 150000,
        error_indicator = false,
        eval_on_move = true,
        error_highlight = 'WarningMsg',
        split_orientation = 'horizontal',
        on_init = function()
            print 'Hello from Luapad!'
        end,
        context = {
            the_answer = 42,
            shout = function(str) return(string.upper(str) .. '!') end
        }
    }

-- " EOF

end

local augr_plugin = vim.api.nvim_create_augroup('AutoGroup_LuaPad',{clear = true})

vim.api.nvim_create_autocmd(
    {'User'}
    ,{pattern = 'PlugLoaded',group= augr_plugin, callback=Load_luapad}
)


-- " augroup LoadLuaPad
-- "   autocmd!
-- "   autocmd User PlugLoaded call LoadLuaPad()
-- " augroup END
