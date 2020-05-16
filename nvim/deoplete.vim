""Deoplete""

let g:deoplete#enable_at_startup = 1
autocmd InsertLeave,CompleteDone * if pumvisible() == 0 | pclose | endif

" inoremap <expr><tab> pumvisible() ? "\<c-n>" : "\<tab>"
imap <expr><TAB>
  \ pumvisible() ? "\<C-n>" :
  \ neosnippet#expandable_or_jumpable() ?
  \    "\<Plug>(neosnippet_expand_or_jump)" : "\<TAB>"
smap <expr><TAB> neosnippet#expandable_or_jumpable() ?
  \ "\<Plug>(neosnippet_expand_or_jump)" : "\<TAB>"

let g:deoplete#sources#jedi#show_docstring = 1

""ALE""

let g:ale_fixers = {
  \'*': ['remove_trailing_lines', 'trim_whitespace'],
  \'javascript': ['prettier', 'eslint'],
  \'css': ['prettier'],
  \'json': ['prettier'],
  \'python': ['yapf', 'isort'],
  \'svelte': ['prettier', 'eslint'],
  \}

let g:ale_fix_on_save = 1
let g:ale_linters_explicit = 1
let g:airline#extensions#ale#enabled = 1
let g:ale_sign_column_always = 1
let g:ale_sign_error = "◉"
let g:ale_sign_warning = "◉"
highlight ALEErrorSign ctermfg=9 ctermbg=15 guifg=#C30500
highlight ALEWarningSign ctermfg=11 ctermbg=15 guifg=#ED6237

nmap <silent> <leader>aj :ALENext<cr>
nmap <silent> <leader>ak :ALEPrevious<cr>

command! ALEToggleFixer execute "let g:ale_fix_on_save = get(g:, 'ale_fix_on_save', 0) ? 0 : 1"

let g:ale_linter_aliases = {'svelte': ['css', 'javascript']}
let g:ale_linters = {'svelte': ['stylelint', 'eslint']}

" Svelte
if !exists('g:context_filetype#same_filetypes')
  let g:context_filetype#filetypes = {}
endif
let g:context_filetype#filetypes.svelte =
  \ [
  \    {'filetype' : 'javascript', 'start' : '<script>', 'end' : '</script>'},
  \    {'filetype' : 'css', 'start' : '<style>', 'end' : '</style>'},
  \ ]
