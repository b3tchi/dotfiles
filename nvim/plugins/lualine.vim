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
