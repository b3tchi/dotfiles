local Plug = vim.fn['plug#']

-- Plug 'brenoprata10/nvim-highlight-colors'
Plug 'folke/which-key.nvim'

function Load_whichkey()

    --WHICH KEY
    local wk = require("which-key")

    wk.setup {
        plugins = {
            spelling = {
                enabled = true, -- enabling this will show WhichKey when pressing z= to select spelling suggestions
                suggestions = 20, -- how many suggestions should be shown in the list?
            },
        },
    }


    function recursemap(mapl, xpath)
        -- print(mapl)
        -- for key in keys(vim.g.which_key_map)
        for key,value in pairs(mapl) do --actualcode
            -- myTable[key] = "foobar"
            -- print(type(value))
            if type(value) == "table" then
                --print(xpath .. key)
                --print(mapl[key]["name"])
                recursemap(value, xpath .. key)
                wk.register({ [xpath .. key] = {mapl[key]["name"]}, })
            else
                -- print(key)
                if key ~= "name" then
                    --print(xpath .. key)
                    --print(mapl[key])
                    wk.register({ [xpath .. key] = {mapl[key]}, })
                end
            end
        end

    end

    recursemap(vim.g.which_key_map,'<space>')
    wk.register({ ["<space>f"] = {"find" }, })


    -- vim.keymap.set('n', '<space>bgh', '<Cmd>DiffviewFileHistory %<CR>', {silent = true, desc='buffer git history'})

end

-- local augr_plugin = vim.api.nvim_create_augroup('AutoGroup_hicolors',{clear = true})

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern = 'PlugLoaded'
        ,group= vim.api.nvim_create_augroup('Load_whichkey',{clear = true})
        ,callback=Load_whichkey
    }
)

