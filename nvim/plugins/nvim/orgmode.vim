"notes taking - NOT USED to be checked
Plug 'nvim-treesitter/nvim-treesitter'
Plug 'nvim-orgmode/orgmode'

function LoadOrgMode()


lua << EOF
require('orgmode').setup_ts_grammar()

-- Tree-sitter configuration
-- If TS highlights are not enabled at all, or disabled via `disable` prop, highlighting will fallback to default Vim syntax highlighting
require'nvim-treesitter.configs'.setup {
  highlight = {
    enable = true,
    additional_vim_regex_highlighting = {'org'}, -- Required for spellcheck, some LaTex highlights and code block highlights that do not have ts grammar
  },
  ensure_installed = {'org'}, -- Or run :TSUpdate org
}

require('orgmode').setup({
  org_agenda_files = {'~/org/projects/*', '~/org/notes/*'},
  org_default_notes_file = '~/org/refile.org',
  org_hide_leading_stars = true,
})
EOF

endfunction

augroup LoadOrgMode
  autocmd!
  autocmd User PlugLoaded call LoadOrgMode()
augroup END
