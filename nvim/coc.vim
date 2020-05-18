" let g:python3_host_prog = '/usr/bin/python3'
" let g:coc_global_extensions = ['coc-explorer', 'coc-json', 'coc-tsserver', 'coc-tslint-plugin', 'coc-highlight', 'coc-snippets', 'coc-template', 'coc-html', 'coc-css', 'coc-emmet', 'coc-python', 'coc-phpls', 'coc-angular', 'coc-git']
"" No CocPython removed other not needed modules 

""Disable some of the modeles like python2
let g:loaded_python_provider = 0
let g:loaded_ruby_provider = 0
let g:loaded_perl_provider = 0

let g:coc_global_extensions = [
  \ 'coc-explorer' 
  \ , 'coc-json'
  \ , 'coc-tsserver'
  \ , 'coc-tslint-plugin'
  \ , 'coc-highlight'
  \ , 'coc-snippets'
  \ , 'coc-template'
  \ , 'coc-html'
  \ , 'coc-css'
  \ , 'coc-emmet'
  \ , 'coc-git'
  \ , 'coc-powershell'
  \ , 'coc-utils'
  \ , 'coc-svelte'
  \ ]


let g:coc_global_extensions += ['https://github.com/andys8/vscode-jest-snippets']

autocmd FileType python let b:coc_root_patterns = [
  \ '.git'
  \, '.env'
  \, 'setup.cfg'
  \, 'setup.py'
  \, 'pyproject.toml'
  \]

function! s:show_documentation()
  if (index(['vim','help'], &filetype) >= 0)
    execute 'h '.expand('<cword>')
  else
    call CocAction('doHover')
  endif
endfunction

" Highlight symbol under cursor on CursorHold
autocmd CursorHold * silent call CocActionAsync('highlight')

augroup mygroup
  autocmd!
  " Setup formatexpr specified filetype(s).
  autocmd FileType typescript,json setl formatexpr=CocAction('formatSelected')
  " Update signature help on jump placeholder
  autocmd User CocJumpPlaceholder call CocActionAsync('showSignatureHelp')
augroup end

hi CocHighlightText guibg=#556873 gui=bold

let g:coc_auto_copen = 0
autocmd User CocQuickfixChange :call fzf_quickfix#run()
