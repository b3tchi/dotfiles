Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}

function LoadedTreeSitter()

lua << EOF
local status, ts = pcall(require, "nvim-treesitter.configs")
if (not status) then return end

ts.setup {
  highlight = {
    enable = true,
    disable = {},
    additional_vim_regex_highlighting = false,
  },
  indent = {
    enable = true,
    disable = {},
  },
  ensure_installed = "all", -- one of "all", "maintained" (parsers with maintainers), or a list of languages
  ignore_install = { "javascript" }, -- List of parsers to ignore installing
  -- ensure_installed = {
  --   "tsx",
  --   "toml",
  --   "fish",
  --   "php",
  --   "json",
  --   "yaml",
  --   "swift",
  --   "css",
  --   "html",
  --   "lua"
  -- },
  autotag = {
    enable = true,
  },
}

local parser_config = require "nvim-treesitter.parsers".get_parser_configs()
parser_config.tsx.filetype_to_parsername = { "javascript", "typescript.tsx" }

--TREESITTER
-- require'nvim-treesitter.configs'.setup {
--   ensure_installed = "all", -- one of "all", "maintained" (parsers with maintainers), or a list of languages
--   ignore_install = { "javascript" }, -- List of parsers to ignore installing
--   highlight = {
--     enable = true,              -- false will disable the whole extension
--     -- disable = { "c", "rust" },  -- list of language that will be disabled
--     -- Setting this to true will run `:h syntax` and tree-sitter at the same time.
--     -- Set this to `true` if you depend on 'syntax' being enabled (like for indentation).
--     -- Using this option may slow down your editor, and you may see some duplicate highlights.
--     -- Instead of true it can also be a list of languages
--     additional_vim_regex_highlighting = false,
--   },
-- }

EOF

endfunction

augroup LoadedTreeSitter
  autocmd!
  autocmd User PlugLoaded call LoadedTreeSitter()
augroup END
