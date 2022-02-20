Plug 'nvim-lualine/lualine.nvim'
Plug 'akinsho/bufferline.nvim'
Plug 'kyazdani42/nvim-web-devicons' " Recommended (for coloured icons)
" Plug 'ryanoasis/vim-devicons' Icons without colours

function LoadedLualine()

command! LightlineReload call LightlineReload()

function! LightlineReload() abort
endfunction
set termguicolors
lua << EOF
require('bufferline').setup()
    local function repopath()
      return vim.fn.expand('%:.')
    end

require('lualine').setup{
  options = {
    icons_enabled = true,
    theme = 'auto',
    component_separators = { left = '', right = ''},
    section_separators = { left = '', right = ''},
    disabled_filetypes = { 'coc-explorer' },
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
  extensions = { 'symbols-outline' ,'fugitive'}
}
EOF
endfunction

augroup LoadedLualine
  autocmd!
  autocmd User PlugLoaded call LoadedLualine()
augroup END
