" Required:
set runtimepath+=~/.cache/dein/repos/github.com/Shougo/dein.vim

" let useCoc = 1
let lspClient = 2 "1 for coc-nvim, 2 for deoplete (WIP), -1 non Lsp Client (TBD)

" Required:
if dein#load_state('~/.cache/dein')
  call dein#begin('~/.cache/dein')

  " Required:
  call dein#add('~/.cache/dein/repos/github.com/Shougo/dein.vim')

  call dein#add('liuchengxu/vista.vim')
  " call dein#add('Yggdroot/indentLine')
  call dein#add('nathanaelkane/vim-indent-guides') "indenting guides
  call dein#add('jeffkreeftmeijer/vim-numbertoggle')		"hybrid/static number toggle when multiple windows
  call dein#add('cohama/lexima.vim')						"autoclosing pairs
  call dein#add('itchyny/lightline.vim')
  call dein#add('mengelbrecht/lightline-bufferline')
  call dein#add('google/vim-searchindex')
  call dein#add('mhinz/vim-startify') "fancty start screen for VIM
  call dein#add('junegunn/fzf', {'build': './install --all', 'merged': 0})
  call dein#add('junegunn/fzf.vim', {'depends': 'fzf'})

  call dein#add('scrooloose/nerdcommenter')
  " call dein#add('tpope/vim-commentary') "comments gcc
  call dein#add('tmsvg/pear-tree')
  call dein#add('editorconfig/editorconfig-vim')

  "mapping help file TBD to make mappings
  call dein#add('liuchengxu/vim-which-key')

  "git
  call dein#add('tpope/vim-fugitive') "git intergration
  call dein#add('airblade/vim-gitgutter') "git intergration

  if lspClient == 1
    call dein#add('neoclide/coc.nvim', {'merge': 0, 'rev': 'release'})
    " call dein#add('neoclide/coc.nvim', {'merge':0, 'build': './install.sh nightly'})
    " call dein#add('mgedmin/python-imports.vim', { 'on_ft' : 'python' })
  elseif lspClient == 2

    call dein#add('Shougo/deoplete.nvim')
    if !has('nvim')
      call dein#add('roxma/nvim-yarp')
      call dein#add('roxma/vim-hug-neovim-rpc')
    endif
    let g:deoplete#enable_at_startup = 1

    call dein#add('dense-analysis/ale')
  endif

  " Svelte
  call dein#add('evanleck/vim-svelte')
  call dein#add('Shougo/context_filetype.vim')

  "syntax highlighting
  call dein#add('sheerun/vim-polyglot')

  call dein#add('janko-m/vim-test')
  "call dein#add('neomake/neomake')

  " themes
  call dein#add('kaicataldo/material.vim')
  call dein#add('altercation/vim-colors-solarized')
  call dein#add('iCyMind/NeoSolarized')
  call dein#add('lifepillar/vim-solarized8')

  " Required:
  call dein#end()
  call dein#save_state()
endif

" Required:
filetype plugin indent on
syntax on
set noshowmode " INSERT déjà affiché par lightbar

autocmd FileType vista,coc-explorer setlocal signcolumn=no

" If you want to install not installed plugins on startup.
call dein#recache_runtimepath() " remove unused unloaded

if dein#check_install()
  call dein#install()
endif

if lspClient == 1
  source ~/.config/nvim/coc.vim
elseif lspClient == 2
  source ~/.config/nvim/deoplete.vim
endif


"End dein Scripts-------------------------

let mapleader = "," " leader key is ,

set number relativenumber ignorecase smartcase undofile lazyredraw
set cursorline
set mouse=a
set hidden
set cmdheight=3
set updatetime=300
set completeopt=noinsert,menuone,preview
set tabstop=2 softtabstop=2 expandtab shiftwidth=2
set splitright splitbelow
set numberwidth=1
set listchars=tab:→\ ,nbsp:␣,trail:•,extends:⟩,precedes:⟨

"" Define folding
set foldmethod=indent

" Traverse line breaks with arrow keys
set whichwrap=b,s,<,>,[,]
set wildmode=longest,list,full

" Set backups
if has('persistent_undo')
  set undofile
  set undolevels=3000
  set undoreload=10000
endif
set backupcopy=yes " for watchers set noswapfile

"" Encoding
set encoding=utf-8
set fileencoding=utf-8
set fileencodings=utf-8

" always show signcolumns
set signcolumn=yes
set clipboard=unnamedplus
set showtabline=2
set laststatus=2
set shortmess+=c
au BufEnter * set fo-=c fo-=r fo-=o                     " stop annying auto commenting on new lines

"" theme material theme
" set termguicolors
" let g:material_terminal_italics = 1
" let g:material_theme_style = 'darker'
" colorscheme material

"" neosolarized theme
" set background=dark
" set termguicolors
" colorscheme NeoSolarized
" let g:neosolarized_bold = 1
" let g:neosolarized_underline = 1
" let g:neosolarized_italic = 1

"" solarized theme
" set t_Co=256
" set background=dark
" colorscheme solarized
" let g:solarized_termcolors=256

"" solarized8 theme
set termguicolors
set background=dark
colorscheme solarized8


" hi Normal guibg=NONE
set fillchars=vert:┃ " for vsplits

" -----------------------------
" --------- Shortcuts ---------
" -----------------------------

map <leader>r :source ~/.config/nvim/init.vim<CR>
nnoremap <C-C> <C-[>
nmap <F9> :Vista!!<CR>

nnoremap <Tab> :bnext!<CR>
nnoremap <S-Tab> :bprev!<CR>

nnoremap <C-p> :GFiles<cr>
nnoremap <C-f> :Rg<cr>

nmap <silent> <leader>tn :TestNearest<CR>
nmap <silent> <leader>tf :TestFile<CR>
nmap <silent> <leader>ts :TestSuite<CR>
nmap <silent> <leader>tl :TestLast<CR>
nmap <silent> <leader>tv :TestVisit<CR>

noremap <F5> :ImportName<cr>:w<cr>:!isort %<cr>:e %<cr>
noremap! <F5> <esc>:ImportName<cr>:w<cr>:!isort %<cr>:e %<cr>a

"" various escapes insert mode
inoremap jk <esc>
cnoremap jk <c-c>
tnoremap <Esc> <C-\><C-n>

"" commenting keybindings
nmap <space>cl <leader>c<space>
"add comment paragraph
nmap <space>cp vip<leader>c<space>
"toggle comment paragrap
nmap <space>cP vip<leader>cc
"toggle comment tag
nmap <space>ct vat<leader>c<space>

"" navigating widows by spaces + number
nnoremap <space>1 :exe 1 . "wincmd w"<CR>
nnoremap <space>2 :exe 2 . "wincmd w"<CR>
nnoremap <space>3 :exe 3 . "wincmd w"<CR>
nnoremap <space>4 :exe 4 . "wincmd w"<CR>
nnoremap <space>5 :exe 5 . "wincmd w"<CR>
nnoremap <space>6 :exe 6 . "wincmd w"<CR>
nnoremap <space>7 :exe 7 . "wincmd w"<CR>
nnoremap <space>8 :exe 8 . "wincmd w"<CR>
nnoremap <space>9 :exe 9 . "wincmd w"<CR>
nnoremap <space>0 :exe 10 . "wincmd w"<CR>

"" indentation
"nnoremap > >>_
"nnoremap < <<_
vnoremap < <gv
vnoremap > >gv

" --- Coc ---
if lspClient == 1
  nnoremap <C-o> :CocCommand explorer<cr>
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

  " Using CocList
  nnoremap <silent> <space>a  :<C-u>CocList diagnostics<cr>
  nnoremap <silent> <space>e  :<C-u>CocList extensions<cr>
  nnoremap <silent> <space>c  :<C-u>CocList commands<cr>
  nnoremap <silent> <space>o  :<C-u>CocList outline<cr>
  nnoremap <silent> <space>s  :<C-u>CocList -I symbols<cr>
  " Do default action for next item.
  nnoremap <silent> <space>j  :<C-u>CocNext<CR>
  " Do default action for previous item.
  nnoremap <silent> <space>k  :<C-u>CocPrev<CR>
  nnoremap <silent> <space>p  :<C-u>CocListResume<CR>

  nnoremap <leader>em :CocCommand python.refactorExtractMethod<cr>
  vnoremap <leader>em :CocCommand python.refactorExtractMethod<cr>
  nnoremap <leader>ev :CocCommand python.refactorExtractVariable<cr>

  " Use tab for trigger completion with characters ahead and navigate.
  " Use command ':verbose imap <tab>' to make sure tab is not mapped by other plugin.
  inoremap <silent><expr> <TAB>
    \ pumvisible() ? "\<C-n>" :
    \ <SID>check_back_space() ? "\<TAB>" :
    \ coc#refresh()
  inoremap <expr><S-TAB> pumvisible() ? "\<C-p>" : "\<C-h>"
  inoremap <expr> <cr> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"

endif
" ----------------------------------
" --------- Plugins config ---------
" ----------------------------------

function s:check_back_space() abort

  let col = col('.') - 1
  return !col || getline('.')[col - 1]  =~# '\s'
endfunction

" go back to where you exited
if has("autocmd")
  autocmd BufReadPost *
    \ if line("'\"") > 0 && line ("'\"") <= line("$") |
    \   exe "normal g'\"" |
    \ endif
endif

" --- Coc ---
"moved to coc.vim

" --- lightline ---
let g:lightline = {
  \ 'colorscheme': 'solarized',
  \ 'active': {
  \     'left': [ [ 'mode', 'paste' ],
  \               [ 'cocstatus','winnr'],
  \               [ 'readonly','filename', 'modified' ] ],
  \ },
  \	'inactive': {
  \	     'left': [ ['winnr'] ,
  \                ['filename' ] ]
  \ },
  \ 'component': {
  \   'winnr': '%{winnr()}',
  \   'filename': '%t',
  \   'lineinfo': '%3l:%-2v',
  \ },
  \ 'component_function': {
  \   'cocstatus': 'coc#status',
  \ },
  \ }

let g:lightline.tabline          = {'left': [['buffers']], 'right': [['close']]}
let g:lightline.component_expand = {'buffers': 'lightline#bufferline#buffers'}
let g:lightline.component_type   = {'buffers': 'tabsel'}

" let g:lightline#bufferline#shorten_path = 1
let g:lightline#bufferline#filename_modifier = ':t'
let g:lightline#bufferline#unnamed      = '[No Name]'
let g:lightline#bufferline#enable_devicons = 1
let g:lightline#bufferline#unicode_symbols = 1

"--- Indent Guides ---
let g:indent_guides_enable_on_vim_startup = 1

"--- Vista ---
let g:vista_default_executive = 'coc'
let g:vista#renderer#enable_icon = 1
let g:vista#renderer#icons = {
\   "function": "\uf794",
\   "variable": "\uf71b",
\  }
let g:vista_icon_indent = ["▸ ", ""]
"g:vista_echo_cursor_strategy = 'both'

" --- fzf ---
let $FZF_DEFAULT_OPTS = '--reverse'
let $BAT_THEME = 'OneHalfDark'
let g:fzf_layout = { 'window': 'call OpenFloatingWin()' }

command! -bang -nargs=* Rg
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-heading --fixed-strings --color=always --glob "!.git/*" --smart-case '.shellescape(<q-args>), 1,
  \   <bang>0 ? fzf#vim#with_preview()
  \           : fzf#vim#with_preview(),
  \   <bang>0)

command! -bang -nargs=? -complete=dir GFiles
  \ call fzf#vim#gitfiles(
  \   <q-args>,
  \   fzf#vim#with_preview(),
  \   <bang>0)

function! OpenFloatingWin()
  let width = min([&columns - 4, max([80, &columns - 20])])
  let height = min([&lines - 4, max([20, &lines - 10])])
  let top = ((&lines - height) / 2) - 1
  let left = (&columns - width) / 2
  let opts = {'relative': 'editor', 'row': top, 'col': left, 'width': width, 'height': height, 'style': 'minimal'}

  let top = "╭" . repeat("─", width - 2) . "╮"
  let mid = "│" . repeat(" ", width - 2) . "│"
  let bot = "╰" . repeat("─", width - 2) . "╯"
  let lines = [top] + repeat([mid], height - 2) + [bot]
  let s:buf = nvim_create_buf(v:false, v:true)
  call nvim_buf_set_lines(s:buf, 0, -1, v:true, lines)
  call nvim_open_win(s:buf, v:true, opts)
  set winhl=Normal:Floating
  let opts.row += 1
  let opts.height -= 2
  let opts.col += 2
  let opts.width -= 4
  call nvim_open_win(nvim_create_buf(v:false, v:true), v:true, opts)
  au BufWipeout <buffer> exe 'bw '.s:buf
endfunction

"--- NERD Commenter ---
"using tpope's commentary
" let g:NERDSpaceDelims = 1
" let g:NERDCompactSexyComs = 1

"--- startify ---
let g:startify_bookmarks = ['~/svn', '~/dev']

"--- indentGuide ---
" let g:indent_guides_color_change_percent = 3 " for auto options left 5 percent only
"color form solarized8
let g:indent_guides_auto_colors = 0
autocmd VimEnter,Colorscheme * :hi IndentGuidesOdd  guibg=#002b36 ctermbg=3
autocmd VimEnter,Colorscheme * :hi IndentGuidesEven guibg=#073642 ctermbg=4

"--- indentLine ---
" let g:indentLine_char               = "⎸"
" let g:indentLine_faster             = 1
" let g:indentLine_fileTypeExclude    = ['json',  'startify', '', 'help', 'coc-explorer']
" let g:indentLine_leadingSpaceEnabled = 1
" let g:indentLine_leadingSpaceChar   = '·'
" let g:indentLine_setConceal = -1

" --- Vim Test ---
let g:test#strategy = 'neovim'

" --- Svelte files reading ---
au! BufNewFile,BufRead *.svelte set ft=html
