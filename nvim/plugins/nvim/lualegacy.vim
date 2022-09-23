lua << EOF
--TREESITTER
require'nvim-treesitter.configs'.setup {
  ensure_installed = "all", -- one of "all", "maintained" (parsers with maintainers), or a list of languages
  ignore_install = { "javascript" }, -- List of parsers to ignore installing
  highlight = {
    enable = true,              -- false will disable the whole extension
    -- disable = { "c", "rust" },  -- list of language that will be disabled
    -- Setting this to true will run `:h syntax` and tree-sitter at the same time.
    -- Set this to `true` if you depend on 'syntax' being enabled (like for indentation).
    -- Using this option may slow down your editor, and you may see some duplicate highlights.
    -- Instead of true it can also be a list of languages
    additional_vim_regex_highlighting = false,
  },
}

--Telescope
-- You dont need to set any of these options. These are the default ones. Only
-- the loading is important
require('telescope').setup {
  extensions = {
    fzf = {
      fuzzy = true,                    -- false will only do exact matching
      override_generic_sorter = true,  -- override the generic sorter
      override_file_sorter = true,     -- override the file sorter
      case_mode = "smart_case",        -- or "ignore_case" or "respect_case"
      -- the default case_mode is "smart_case"
      }
  }
}

--require("telescope").load_extension("git_worktree")
require("telescope").load_extension("fzf")

-- To get fzf loaded and working with telescope, you need to call
-- load_extension, somewhere after setup function:

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
