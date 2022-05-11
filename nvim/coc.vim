Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'antoinemadec/coc-fzf', {'branch': 'release'}
" Plug 'neoclide/coc.nvim', {'merge': 0, 'rev': 'release'}

" Plug 'liuchengxu/vista.vim'
" Plug 'neoclide/coc.nvim', {'do': 'yarn install --frozen-lockfile'}
" Plug 'neoclide/coc.nvim', {'merge':0, 'build': './install.sh nightly'}
" Plug 'mgedmin/python-imports.vim', { 'on_ft' : 'python' }

"" Computer specific settings
if g:os == 'Windows'
  if match(g:computerName,'DESKTOP-HSRFLH5') == 0
    let g:python3_host_prog='c:\Program Files (x86)\Python37-32\python.exe'
  elseif g:computerName == 'Something Else'
    let g:python3_host_prog='c:\Program Files (x86)\Python36-32\python.exe'
  endif
elseif g:os == 'Android'
  let g:python3_host_prog = '/data/data/com.termux/files/usr/bin/python'
else
  let g:python3_host_prog = '/usr/bin/python3'
endif

" let g:python3_host_prog='c:\Users\czJaBeck\AppData\Local\Microsoft\WindowsApps\python.exe'
"" No CocPython removed other not needed modules
"" Node path to specify if needed
" let g:coc_node_path = '/c/Program Files/nodejs/node'

""Disable some of the modeles like python2
let g:loaded_python_provider=0
let g:loaded_ruby_provider=0
let g:loaded_perl_provider=0

let g:coc_global_extensions = [
  \ 'coc-explorer'
  \ , 'coc-highlight'
  \ , 'coc-html'
  \ , 'coc-emmet'
  \ , 'coc-css'
  \ , 'coc-git'
  \ , 'coc-db'
  \ , 'coc-json'
  \ , 'coc-yaml'
  \ ]

"" Migrated to seperated file
  " \ , 'coc-snippets'
  " \ , 'coc-tsserver'
  " \ , 'coc-tslint-plugin'
  " \ , 'coc-svelte'
  " \ , 'coc-powershell'

"" Depracated modules
  " \ , 'coc-utils'
  " \ , 'coc-template'

let g:coc_global_extensions += ['https://github.com/andys8/vscode-jest-snippets']

function! s:show_documentation()
  if (index(['vim','help'], &filetype) >= 0)
    execute 'h '.expand('<cword>')
  else
    call CocAction('doHover')
  endif
endfunction


hi CocHighlightText guibg=#556873 gui=bold

let g:coc_auto_copen = 0
function LoadedCoc()
  " echom "gruvRun"
  autocmd FileType python let b:coc_root_patterns = [
    \ '.git'
    \, '.env'
    \, 'setup.cfg'
    \, 'setup.py'
    \, 'pyproject.toml'
    \]

  " Highlight symbol under cursor on CursorHold
  autocmd CursorHold * silent call CocActionAsync('highlight')

  augroup mygroup
    autocmd!
    " Setup formatexpr specified filetype(s).
    autocmd FileType typescript,json setl formatexpr=CocAction('formatSelected')
    " Update signature help on jump placeholder
    autocmd User CocJumpPlaceholder call CocActionAsync('showSignatureHelp')
  augroup end

  autocmd User CocQuickfixChange :call fzf_quickfix#run()
" let g:coc_force_debug = 1
  " Remap keys for gotos
  nmap <silent> gd <Plug>(coc-definition)
  nmap <silent> gy <Plug>(coc-type-definition)
  nmap <silent> gi <Plug>(coc-implementation)
  nmap <silent> gr <Plug>(coc-references)


  " Use K for show documentation in preview window
  nnoremap <silent> K :call <SID>show_documentation()<CR>
  " Remap for rename current word
  nmap <leader>rn <Plug>(coc-rename)
  " Remap for format selected region
  xmap <leader>f  <Plug>(coc-format-selected)
  nmap <leader>f  <Plug>(coc-format-selected)
  " Remap for do codeAction of selected region, ex: `<leader>aap` for current paragraph
  xmap <leader>a  <Plug>(coc-codeaction-selected)
  nmap <leader>a  <Plug>(coc-codeaction-selected)
  " Remap for do codeAction of current line
  nmap <leader>ac  <Plug>(coc-codeaction)
  " Fix autofix problem of current line
  nmap <leader>qf  <Plug>(coc-fix-current)
  nmap <a-cr>  <Plug>(coc-fix-current)
  " Use <C-d> for select selections ranges, needs server support, like: coc-tsserver, coc-python
  nmap <expr> <silent> <C-d> <SID>select_current_word()

  function! s:select_current_word()
    if !get(g:, 'coc_cursors_activated', 0)
      return "\<Plug>(coc-cursors-word)"
    endif
    return "*\<Plug>(coc-cursors-word):nohlsearch\<CR>"
  endfunc

  " Use `:Format` for format current buffer
  command! -nargs=0 Format :call CocAction('format')

  " nnoremap <C-o> :CocCommand explorer<cr>
  " Using CocList
  "TBR Vista succed by fzf-coc
  " nmap <silent>  o :<cr>

  nnoremap <silent> <space>vfc :<C-u>CocFzfList commands<cr>
  nnoremap <silent> <space>a :<C-u>CocFzfList diagnostics<cr>
  nnoremap <silent> <space>E :CocCommand explorer<cr>
  nnoremap <silent> <space>o :<C-u>CocFzfList outline<cr>
  nnoremap <silent> <space>O :SymbolsOutline<CR>
  " nnoremap <silent>  e  :<C-u>CocList extensions<cr>
  " nnoremap <silent>  s  :<C-u>CocList -I symbols<cr>

  " CocList Navigation - Do default action for next item.
  " nnoremap <silent>  j  :<C-u>CocNext<CR>
  " nnoremap <silent>  k  :<C-u>CocPrev<CR>
  nnoremap <silent> <space>p :<C-u>CocFzfListResume<CR>
  " Do default action for previous item.

  nnoremap <leader>em :CocCommand python.refactorExtractMethod<cr>
  vnoremap <leader>em :CocCommand python.refactorExtractMethod<cr>
  nnoremap <leader>ev :CocCommand python.refactorExtractVariable<cr>

  " Use tab for trigger completion with characters ahead and navigate.
  " Use command ':verbose imap <tab>' to make sure tab is not mapped by other plugin.
  inoremap <silent><expr> <TAB>
    \ pumvisible() ? "\<C-n>" :
    \ <SID>check_back_space() ? "\<TAB>" :
    \ coc#refresh()
  inoremap <silent><expr> <C-Space>
    \ pumvisible() ? "\<C-n>" :
    \ <SID>check_back_space() ? "\<TAB>" :
    \ coc#refresh()

endfunction

augroup LoadedCoc
  autocmd!
  autocmd User PlugLoaded call LoadedCoc()
augroup END

