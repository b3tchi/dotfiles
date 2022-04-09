Plug 'nvim-lualine/lualine.nvim'
Plug 'akinsho/bufferline.nvim'
Plug 'kyazdani42/nvim-web-devicons' " Recommended (for coloured icons)
" Plug 'ryanoasis/vim-devicons' Icons without colours

function LoadedLualine()

"kept for compatibility with lightline
command! LightlineReload call LightlineReload()
function! LightlineReload() abort
endfunction

"load items
lua << EOF
vim.opt.termguicolors = true

  require('bufferline').setup {
    options = {
      offsets = {
        {filetype = "coc-explorer", text = "File Explorer" , text_align = "center"},
        {filetype = "dbui", text = "Db Explorer" , text_align = "center"},
        {filetype = "Outline", text = "Outline" , text_align = "center"},
      },
    }
  }

  local function repopath()
    return vim.fn.expand('%:.')
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
  local dbui_ext = { sections = { lualine_a = {'filetype'} }, filetypes = {'dbui'} }

require('lualine').setup{
  options = {
    icons_enabled = true,
    theme = 'auto',
    component_separators = { left = '', right = ''},
    section_separators = { left = '', right = ''},
    disabled_filetypes = { },
    always_divide_middle = true,
  },
  sections = {
    lualine_a = {'mode'},
    lualine_b = {'diff', 'diagnostics'},
    lualine_c = { repopath },
    lualine_x = {'encoding', 'filetype'},
    lualine_y = {'progress'},
    lualine_z = {'location'}
  },
  inactive_sections = {
    lualine_a = {},
    lualine_b = {},
    lualine_c = { repopath },
    lualine_x = {'location'},
    lualine_y = {},
    lualine_z = {}
  },
  tabline = {},
  extensions = { 'symbols-outline', 'fugitive', coc_ext, dbui_ext }
}
EOF
endfunction

augroup LoadedLualine
  autocmd!
  autocmd User PlugLoaded call LoadedLualine()
augroup END
