Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-telescope/telescope-fzf-native.nvim',  { 'do': 'make' }

function LoadedTelescope()

lua << EOF

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


EOF

  nnoremap <silent> <space>ff :Rg<cr>
  nnoremap <silent> <space>fc :Telescope grep_string searches=<C-r><C-w><cr>
  nnoremap <silent> <space>ls :Telescope lsp_document_symbols<cr>

endfunction

augroup LoadedTelescope
  autocmd!
  autocmd User PlugLoaded call LoadedTelescope()
augroup END
