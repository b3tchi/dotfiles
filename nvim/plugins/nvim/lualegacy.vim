lua << EOF

--INDENT GUIDES
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

--COMMENTS
require("Comment").setup()

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


EOF
