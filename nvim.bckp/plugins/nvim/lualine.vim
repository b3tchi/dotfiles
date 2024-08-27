Plug 'kyazdani42/nvim-web-devicons' " Recommended (for coloured icons)
Plug 'nvim-lualine/lualine.nvim'
" Plug 'akinsho/bufferline.nvim', { 'tag': 'v1.*' }
" Plug 'ryanoasis/vim-devicons' Icons without colours

function! LoadedLualine()
  " command! LightlineReload call LightlineReload()

  "just for compatibility
  " function! LightlineReload() abort
  " endfunction

"load items
lua << EOF
-- vim.opt.termguicolors = true
--
-- require('bufferline').setup {
--   options = {
--     offsets = {
--       {filetype = "coc-explorer", text = "File Explorer" , text_align = "center"},
--       {filetype = "neo-tree", text = "File Explorer" , text_align = "center"},
--       {filetype = "dbui", text = "Db Explorer" , text_align = "center"},
--       {filetype = "Outline", text = "Outline" , text_align = "center"},
--     },
--   }
-- }

local function repopath()
  return vim.fn.expand('%:.')
end

local colors = {
  -- bg       = '#202328',
  -- fg       = '#bbc2cf',
  -- yellow   = '#ECBE7B',
  -- cyan     = '#008080',
  -- darkblue = '#081633',
  -- violet   = '#a9a1e1',
  -- magenta  = '#c678dd',
  green    =  vim.g.terminal_color_10,
  orange   =  '#fe8019',
  gray     =  vim.g.terminal_color_8,
  blue     =  vim.g.terminal_color_12,
  red      =  vim.g.terminal_color_9,
}

local modes = {
  n = {name = 'NORMAL',bg = colors.gray},
  i = {name = 'INSERT',bg = colors.blue},
  v = {name = 'VISUAL',bg = colors.yellow},
  [''] = {name = 'V-Block',bg = colors.yellow},
  V = {name = 'V-Line',bg = colors.yellow},
  c = {name = 'COMMAND', bg = colors.green},
  R = {name = 'REPLACE', bg = colors.red},
  Rv = {name = 'V-Replace', bg = colors.red},
  t = {name = 'TERMINAL', bg = colors.green},
}

local hydracolor = {
  amaranth = {bg = colors.red},
  teal = {bg = colors.blue},
  pink = {bg = colors.red},
  red = {bg = colors.red},
  blue = {bg = colors.blue},
}

local hydrastatus = require('hydra.statusline')

local function hydraname()

  local hname = hydrastatus.get_name()

  if (hname == nil) then
    return modes[vim.fn.mode()].name
  else
    return hydrastatus.get_name()
  end

end

local function hydracolorx()

  local hname = hydrastatus.get_name()

  if (hname == nil) then
    return modes[vim.fn.mode()].bg
  else
    return hydracolor[hydrastatus.get_color()].bg
  end

end

--- @param trunc_width number trunctates component when screen width is less then trunc_width
--- @param trunc_len number truncates component to trunc_len number of chars
--- @param hide_width number hides component when window width is smaller then hide_width
--- @param no_ellipsis boolean whether to disable adding '...' at end after truncation
--- return function that can format the component accordingly
local function trunc(trunc_width, trunc_len, hide_width, no_ellipsis)
  return function(str)
    local win_width = vim.fn.winwidth(0)
    if hide_width and win_width < hide_width then return ''
    elseif trunc_width and trunc_len and win_width < trunc_width and #str > trunc_len then
       return str:sub(1, trunc_len) .. (no_ellipsis and '' or '...')
    end
    return str
  end
end

-- require'lualine'.setup {
--   lualine_a = {
--     {'mode', fmt=trunc(80, 4, nil, true)},
--     {'filename', fmt=trunc(90, 30, 50)},
--     {function() return require'lsp-status'.status() end, fmt=truc(120, 20, 60)}
--   }
-- }
local coc_ext = { sections = { lualine_a = {'filetype'} }, filetypes = {'coc-explorer'} }
local ntree_ext = { sections = { lualine_a = {'filetype'} }, filetypes = {'neo-tree'} }
local dbui_ext = { sections = { lualine_a = {'filetype'} }, filetypes = {'dbui'} }

local lualine = require('lualine')

local config = {
-- require('lualine').setup{
  options = {
    icons_enabled = true,
    theme = 'auto',
    component_separators = { left = '', right = ''},
    section_separators = { left = '', right = ''},
    disabled_filetypes = { },
    always_divide_middle = true,
  },
  sections = {
    lualine_a = {},
    lualine_b = {repopath, 'diff' },
    lualine_c = {},
    lualine_x = {'encoding', 'filetype', 'diagnostics'},
    lualine_y = {'progress'},
    lualine_z = {'location'}
  },
  inactive_sections = {
    lualine_a = {},
    lualine_b = { repopath },
    lualine_c = {},
    lualine_x = {'location'},
    lualine_y = {},
    lualine_z = {}
  },
  tabline = {},
  extensions = { 'symbols-outline', 'neo-tree','fugitive', coc_ext, dbui_ext }
}

-- Inserts a component in lualine_c at left section
local function ins_left(component)
  table.insert(config.sections.lualine_a, component)
end

-- call function
ins_left {
  -- mode component
  function()
    return hydraname()
  end,
  color = function()
    return { bg = hydracolorx(), gui = 'bold' }
  end,
}

lualine.setup(config)

EOF
endfunction

augroup LoadedLualine
  autocmd!
  autocmd User PlugLoaded call LoadedLualine()
augroup END
