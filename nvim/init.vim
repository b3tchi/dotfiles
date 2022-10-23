if &compatible
  set nocompatible
endif

" Required:
" let useCoc = 1
let g:lspClient = 3 "1 for coc-nvim, 2 for deoplete (WIP), 3 neovim native, -1 non Lsp Client (TBD)
" let g:vimTheme = 2 "1 solarized8, 2 gruvbox

" Identify Os and Actual Device - Who is coming home?
let g:wsl = 0 "default wsl flag to 0
if !exists("g:os")
  if has("win64") || has("win32") || has("win16")
    let g:os = "Windows"
    let g:computerName = substitute(system('hostname'), '\.\_.*$', '', '')
    let g:computerName = substitute(g:computerName, '\n', '', '')
  else
    let g:os = substitute(system('uname'), '\n', '', '')
    let g:computerName = substitute(system('hostname'), '\n', '', '')
    if g:os == 'Linux'
      " uname -o => returns Android on DroidVim, Termux
      if match(system('uname -o'),'Android') == 0
        let g:os = substitute(system('uname -o'), '\n', '', '')
        " let g:os = system('uname -o')
      endif

      " check if running linux in wsl
      if system('$PATH')=~ '/mnt/c/WINDOWS'
        let g:wsl = 1
      endif

    endif
  endif
endif

""decide whot is vim model, 1 vim, pre-0.5 nvim, 0.5+ nvim
function! VimMode()
  if has("nvim")
    let vimver = matchstr(execute('version'), 'NVIM v\zs[^\n]*')
    let verarr = split(vimver,"\\.")
    if str2float(join([verarr[0],verarr[1]],".")) >= 0.5
      return 3
    else
      return 2
    endif
  else
    return 1
  endif
endfunction

let g:vimmode = VimMode()

" let vimplug_exists=expand('~/AppData/Local/nvim-data/site/autoload/plug.vim')
" let vimplug_exists=expand('~/.vim/autoload/plug.vim') "old path
" fix vim plug path for neovim - DONE -> Testing
let vimplug_exists=expand('~/.local/share/nvim/site/autoload/plug.vim') "neovim fixed path

if !filereadable(vimplug_exists)
  if !executable("curl")
    echoerr "You have to install curl or first install vim-plug yourself!"
    execute "q!"
  endif
  echo "Installing Vim-Plug..."
  echo ""

  silent exec "!\curl -fLo " . vimplug_exists
    \ . " --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim"
  let g:not_finish_vimplug = "yes"
  " autocmd VimEnter * PlugInstall "replaced by check further
endif

" Install vim-plug if not found suggested way
" if empty(glob('~/.vim/autoload/plug.vim'))
"   "silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
"   "  \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
"   !curl -fLo ~/.local/share/nvim/site/autoload/plug.vim --create-dirs
"     \ https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
" endif

" clobal variables
let g:which_key_map =  {}
let g:which_key_map.v ={'name':'+vim'}
let g:which_key_map.v.h ={'name':'+help'}

" Required
call plug#begin(expand('~/.vim/plugged'))
" call plug#begin()


  ""General Vim Plugins
  Plug 'jeffkreeftmeijer/vim-numbertoggle'		"hybrid/static number toggle when multiple windows
  Plug 'google/vim-searchindex'
  Plug 'embear/vim-localvimrc' "loading rootfolder placed vim configs /.lvimrc
  Plug 'ryanoasis/vim-devicons' "nerd fonts icons

  ""Welcome & Session Management
  source ~/dotfiles/nvim/plugins/vim/startify.vim

  ""Searching fzf
  source ~/dotfiles/nvim/plugins/vim/fzf.vim

  Plug 'jesseleite/vim-agriculture' "adding option for :RgRaw to run raw commands
  " Plug 'jremmen/vim-ripgrep' "testing ripgrep single addin :Rg in fzf seems broken

  "" White Space Highlighter
  Plug 'ntpeters/vim-better-whitespace'

  ""Autoclosing pairs""
  Plug 'cohama/lexima.vim'
  Plug 'editorconfig/editorconfig-vim' " not used to be investigated
  Plug 'tpope/vim-surround' "surrounding words with symbols
  "Plug 'tmsvg/pear-tree' "getting some issues for the function disabled

  "dim iniactive panes
  " source ~/dotfiles/nvim/plugins/nvim/shadenvim.vim
  " source ~/dotfiles/nvim/plugins/vim/viminactive.vim

  " Plug 'junegunn/gv.vim' "git tree - simplier version of flog
  " Plug 'gregsexton/gitv', {'on': ['Gitv']}
  Plug 'powerman/vim-plugin-AnsiEsc'

  Plug 'mmai/vim-markdown-wiki'
  Plug 'dhruvasagar/vim-table-mode'


  ""vimwiki - personal notes
  " Plug 'vimwiki/vimwiki'
  " Plug 'fcpg/vim-waikiki'

  ""addvanced ide features
  if g:lspClient == 1
    source ~/dotfiles/nvim/plugins/vim/coc.vim
  elseif g:lspClient == 2
    source ~/dotfiles/nvim/plugins/vim/deoplete.vim
  endif

  " Svelte
  Plug 'evanleck/vim-svelte'
  Plug 'mattn/emmet-vim'

  " Plug 'tyru/caw.vim' "comments with context regions
  " Plug 'b3tchi/caw.vim' "comments with context regions addition for svelte TEST
  " Plug 'scrooloose/nerdcommenter'
  " Plug 'tpope/vim-commentary' "comments gcc

  "Window management SuckLess
  Plug 'fabi1cazenave/suckless.vim'

  "Tmux
  source ~/dotfiles/nvim/plugins/vim/vimux.vim


  "install dap for vim
  " source ~/dotfiles/nvim/plugins/vim/vimspector.vim

  "" Old Addins TBD
  "Plug 'janko-m/vim-test'
  "Plug 'neomake/neomake'

  "Adding dadbod for databases
  source ~/dotfiles/nvim/plugins/vim/dadbod.vim

  "Run command async
  Plug 'skywind3000/asyncrun.vim'

  "Git
  source ~/dotfiles/nvim/plugins/vim/git.vim

  " vimmode 3 => Neovim 0.5+ with lua
  if g:vimmode == 3


    " syntax and grammatics
    " Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'} "LSP based highlighting
    "to fix the iisue with slow markdown
    "https://github.com/nvim-treesitter/nvim-treesitter/issues/2206
    " Plug 'nvim-treesitter/nvim-treesitter', {'commit': '8ada8faf2fd5a74cc73090ec856fa88f34cd364b', 'do': ':TSUpdate'}
    Plug 'nvim-lua/popup.nvim'
    Plug 'nvim-lua/plenary.nvim'

    "language server implementation
    source ~/dotfiles/nvim/plugins/nvim/lualsp.vim

    "markdown files
    source ~/dotfiles/nvim/plugins/nvim/mdpreview.vim
    " source ~/dotfiles/nvim/plugins/nvim/telekasten.vim will try orgmode

    "lspsaga WIP issues on loading moved to lualsp
    " source ~/dotfiles/nvim/plugins/nvim/lspsaga.vim

    "lsp navigation moved to lualsp
    " source ~/dotfiles/nvim/plugins/nvim/nvimnavic.vim

    "TBR with mason bellow kept for now
    " Plug 'williamboman/nvim-lsp-installer' "automatic installer of LSPs

    "nvim-lsp-installer mk.2
    source ~/dotfiles/nvim/plugins/nvim/mason.vim

    " LSP List [https://github.com/neovim/nvim-lspconfig/blob/master/CONFIG.md#svelte]

    "syntax highlight support
    " Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}
    source ~/dotfiles/nvim/plugins/nvim/treesitter.vim

    "telescope search instead of fzf
    " Plug 'nvim-telescope/telescope.nvim'
    " Plug 'nvim-telescope/telescope-fzf-native.nvim',  { 'do': 'make' }
    source ~/dotfiles/nvim/plugins/nvim/telescope.vim

    ""nice headlines
    source ~/dotfiles/nvim/plugins/nvim/headlines.vim


    "Status bufferline
    source ~/dotfiles/nvim/plugins/nvim/barbar.vim
    " source ~/dotfiles/nvim/plugins/nvim/bufferline.vim

    ""Indent guides
    Plug 'lukas-reineke/indent-blankline.nvim'

    "orgmode
    source ~/dotfiles/nvim/plugins/nvim/orgmode.vim

    "completion
    source ~/dotfiles/nvim/plugins/nvim/nvmcmp.vim

    "debugger
    source ~/dotfiles/nvim/plugins/nvim/nvimdap.vim

    "folds
    source ~/dotfiles/nvim/plugins/nvim/foldufo.vim

    "git missing some features
    " source ~/dotfiles/nvim/plugins/nvim/git.vim
    " Plug 'ThePrimeagen/git-worktree.nvim'

    "outlines
    Plug 'simrat39/symbols-outline.nvim' "outlines

   ""Indent guides
    Plug 'lukas-reineke/indent-blankline.nvim'

    ""Treesitter backed comments
    Plug 'numToStr/Comment.nvim'
    " Plug 'waylonwalker/Telegraph.nvim' "interesting idea simple using vimux nox

    "lua extended version of which key
    Plug 'folke/which-key.nvim'

    " themes have to be before lualine
    source ~/dotfiles/nvim/plugins/nvim/gruvboxnvim.vim

    "scrollbar
    source ~/dotfiles/nvim/plugins/nvim/scrollbar.vim

    "Status luaLine
    source ~/dotfiles/nvim/plugins/nvim/lualine.vim

    "custom modes
    source ~/dotfiles/nvim/plugins/nvim/hydra.vim

    "file explorer
    source ~/dotfiles/nvim/plugins/nvim/neotree.vim
    " source ~/dotfiles/nvim/plugins/nvim/nvimtree.vim

  else "pre-neovim

    " Support for comments symbol by language regions Svelte & Html
    Plug 'Shougo/context_filetype.vim' "language regions in files

    " Another Comment Pluging with HTML region support
    Plug 'tomtom/tcomment_vim'

    "mapping help file TBD to make mappings
    Plug 'liuchengxu/vim-which-key'

    ""Indent guides
    Plug 'b3tchi/iguides' "improved guides
    " Plug 'Yggdroot/indentLine'
    " Plug 'thaerkh/vim-indentguides'
    " Plug 'lukas-reineke/indent-blankline.nvim'
    " Plug 'nathanaelkane/vim-indent-guides' "indenting guides

    ""Status Line & bufferline
    source ~/dotfiles/nvim/plugins/vim/lightline.vim

    " themes
    source ~/dotfiles/nvim/plugins/vim/gruvbox.vim
    " source ~/dotfiles/nvim/plugins/vim/solarized.vim
    " source ~/dotfiles/nvim/plugins/nvim/gruvboxnvim.vim

    "syntax highlighting
    Plug 'sheerun/vim-polyglot'

    " Plug 'lifepillar/vim-solarized8'
    " Plug 'morhetz/gruvbox'
    " Plug 'kaicataldo/material.vim'
    " Plug 'altercation/vim-colors-solarized'
    " Plug 'iCyMind/NeoSolarized'

    source ~/dotfiles/nvim/plugins/vim/markdown.vim
  endif

call plug#end()

" Run PlugInstall if there are missing plugins
" autocmd VimEnter * if len(filter(values(g:plugs), '!isdirectory(v:val.dir)'))
  " \| PlugInstall --sync | source $MYVIMRC
" \| endif

" Run PlugInstall if there are missing plugins
if len(filter(values(g:plugs), '!isdirectory(v:val.dir)'))
  PlugInstall --sync ""| source $MYVIMRC
endif

" echom "plugend"
"event triggering after plug
doautocmd User PlugLoaded
" echom "plugafterevent"


" Allow gf to open non-existent files
map gf :edit <cfile><cr>

" Required:
syntax on
" filetype plugin indent on
set noshowmode " INSERT déjà affiché par lightbar

autocmd FileType vista,coc-explorer setlocal signcolumn=no

"languages
source ~/dotfiles/nvim/languages/bash.vim
source ~/dotfiles/nvim/languages/yaml.vim
source ~/dotfiles/nvim/languages/powershell.vim "ENABLED TESTING mason
source ~/dotfiles/nvim/languages/csharp.vim
source ~/dotfiles/nvim/languages/terraform.vim
source ~/dotfiles/nvim/languages/typescript.vim
source ~/dotfiles/nvim/languages/otherlangs.vim

"script for vim terminal
source ~/dotfiles/nvim/scripts/vim/incubator.vim

let mapleader = "," " leader key is ,

set number relativenumber ignorecase smartcase undofile lazyredraw
set cursorline
set mouse=a
set hidden
set cmdheight=3
set updatetime=300
set completeopt=noinsert,menuone,preview
set splitright splitbelow
set numberwidth=1
set title "for Session title names
" set listchars=tab:→\ ,nbsp:␣,trail:•,extends:⟩,precedes:⟨
"" Set improve search UX with realtime results
"" incremental search
set incsearch
set hlsearch

"indentations spaces
" 2 indent are easier to complicate code let's take 4

set tabstop=4
set softtabstop=4
set expandtab
set shiftwidth=4

"" Define folding
" set foldmethod=indent
" set foldlevelstart=20
" highlight Folded
"
" " set foldmethod=syntax
" set foldignore=

if g:vimmode == 1
	source ~/dotfiles/nvim/scripts/vim/folding.vim
end
" set listchars=tab:\|\
" set list

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
set scrolloff=8

"" Encoding
set encoding=utf-8
set fileencoding=utf-8
set fileencodings=utf-8

"spelling
set spelllang=en
set spellsuggest=best,9 " Show nine spell checking candidates at most
hi SpellBad cterm=underline ctermfg=red

" always show signcolumns
set signcolumn=yes
set clipboard=unnamedplus
set showtabline=2
set laststatus=2
set shortmess+=c
au BufEnter * set fo-=c fo-=r fo-=o                     " stop annying auto commenting on new lines

""file netrw
let g:netrw_banner = 0
let g:netrw_liststyle = 3
let g:netrw_browse_split = 4
let g:netrw_altv = 1
let g:netrw_winsize = 25

""cliboard for wsl
if g:wsl == 1
  augroup Yank
    autocmd!
    autocmd TextYankPost * :call system('/mnt/c/windows/system32/clip.exe ',@")
  augroup END
endif

" augroup ProjectDrawer:
"   autocmd!
"   autocmd VimEnter * :Vexplore
" augroup END

set fillchars=vert:┃ " for vsplits

" -----------------------------
" --------- Shortcuts ---------
" -----------------------------{{{

nnoremap <C-C> <C-[>

if g:vimmode != 3
  call which_key#register('<Space>', "g:which_key_map")
  " which key
  nnoremap <silent><space> :WhichKey ' '<CR>
endif

let g:which_key_map.b = '+buffer'
" nnoremap <silent> <space>bb :Buffers<cr>
nnoremap <silent> <space>bb :Telescope buffers<cr>
nnoremap <silent> <space>bs :StripWhitespace<cr>
nnoremap <silent> <space>bl :LspInfo<cr>

" nnoremap <C-p> :GFiles<cr>
" nnoremap <C-f> :Rg<cr>
" nnoremap <silent> <space>f :Rg<cr>
" nnoremap <silent> ;; :Buffer<cr>
" nnoremap <silent> <space>ee :call FuzzyFiles()<cr>
" nnoremap <silent> <space>W :Windows<cr>

" function FuzzyFiles()
"   if get(b:,'git_dir') == 0
"     exe ':FzfFiles'
"   else
"     exe ':GFiles'
"   endif
" endfunction

"tasks TBD
" nnoremap <silent> <space>tn :Trep<cr>

" nnoremap <silent> <space>vk :Maps<cr>
" let g:which_key_map.v.h ={'name':'+help'}
" nnoremap <silent> <space>vhf :Helptags<cr>

let g:which_key_map.v.p ={'name':'+plug'}
nnoremap <silent> <space>vpu :PlugUpdate<cr>
nnoremap <silent> <space>vpi :PlugStatus<cr>
nnoremap <silent> <space>vpc :PlugClean<cr>

let g:which_key_map.v.i ={'name':'+init.vim'}
" nnoremap <space>viu :source ~/.config/nvim/init.vim<cr>:LightlineReload<cr>
nnoremap <space>viu :source ~/.config/nvim/init.vim<cr>

let g:which_key_map.v.l ={'name':'+lsp'}
nnoremap <silent> <space>vli :LspInstallInfo<cr>
 " If text is selected, save it in the v buffer and send that buffer it to tmux

nmap <silent> <leader>tn :TestNearest<CR>
nmap <silent> <leader>tf :TestFile<CR>
nmap <silent> <leader>ts :TestSuite<CR>
nmap <silent> <leader>tl :TestLast<CR>
nmap <silent> <leader>tv :TestVisit<CR>

nnoremap <space>rc :%s/<C-r><C-w>//gc<Left><Left><Left>
nnoremap <space>rr :%s/<C-r>"//gc<Left><Left><Left>

noremap <F5> :ImportName<cr>:w<cr>:!isort %<cr>:e %<cr>
noremap! <F5> <esc>:ImportName<cr>:w<cr>:!isort %<cr>:e %<cr>a

""u various escapes insert mode
inoremap jj <esc>
cnoremap jj <c-c>
tnoremap jj <C-\><C-n>
" nmap    <Esc>
" tnoremap <Esc> <C-\><C-n>

"" commenting keybindings
" nmap <space>cl <leader>c
" "add comment paragraph
" nmap <space>cp vip<leader>c
" "toggle comment paragrap
" nmap <space>cP vip<leader>cc
" "toggle comment tag
" nmap <space>ct vat<leader>c

"" navigating widows by spaces + number
nnoremap <silent><space>1 :exe 1 . "wincmd w"<CR>
nnoremap <silent><space>2 :exe 2 . "wincmd w"<CR>
nnoremap <silent><space>3 :exe 3 . "wincmd w"<CR>
nnoremap <silent><space>4 :exe 4 . "wincmd w"<CR>
nnoremap <silent><space>5 :exe 5 . "wincmd w"<CR>
nnoremap <silent><space>6 :exe 6 . "wincmd w"<CR>
nnoremap <silent><space>7 :exe 7 . "wincmd w"<CR>
nnoremap <silent><space>8 :exe 8 . "wincmd w"<CR>
nnoremap <silent><space>9 :exe 9 . "wincmd w"<CR>
nnoremap <silent><space>0 :exe 10 . "wincmd w"<CR>

" navigiting through windows with j and k
nnoremap <C-j> <c-w>j
nnoremap <C-k> <c-w>k
nnoremap <C-h> <c-w>h
nnoremap <C-l> <c-w>l

" nnoremap <C-k> <c-w>W
" nnoremap <C-j> <c-w>w

function SwitchMainWindow()
  let l:current_buf = winbufnr(0)
  exe "buffer" . winbufnr(1)
  1wincmd w
  exe "buffer" . l:current_buf
endfunction

"manipulation
nnoremap <space>ws <c-w>v
nnoremap <space>wb <c-w>s
nnoremap <space>wc <c-w>c
nnoremap <space>wm :call SwitchMainWindow()<cr>
nnoremap <space>wo :only<cr>
nnoremap <space>wl <c-w>p

"" indentation
"nnoremap > >>_
"nnoremap < <<_
vnoremap < <gv
vnoremap > >gv

" --- Vim Wiki ---
nnoremap <silent><space>Wt :VimwikiTable 1 2

" --- Coc ---
" moved to coc.vim

nnoremap <Tab> :bnext!<CR>
nnoremap <S-Tab> :bprev!<CR>

nnoremap <C-Tab> :bnext!<CR>
nnoremap <S-C-Tab> :bprev!<CR>

" inoremap <expr><S-TAB> pumvisible() ? "\<C-p>" : "\<C-h>"
" inoremap <expr><C-S-Space> pumvisible() ? "\<C-p>" : "\<C-h>"

" inoremap <expr> <cr> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"
" inoremap <expr> <CR> pumvisible() ? "\<C-y>" : "\<CR>"

" tmap <S-TAB> <Nop>
" tmap <TAB> <Nop>

"}}}
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

" --- local vimrc ---
"diable prompts on folder change
let g:localvimrc_sandbox = 0
let g:localvimrc_ask = 0

"--- Vista ---
"moved to coc.vim

let $BAT_THEME = 'gruvbox' "need bat 16.0 and higher
" let $BAT_THEME = 'OneHalfDark'

let g:rg_derive_root='true'

"--- NERD Commenter ---
"using tpope's commentary
" let g:NERDSpaceDelims = 1
" let g:NERDCompactSexyComs = 1
highlight Comment cterm=italic


"--- startify ---
"moved to startify.vim

"--- Indent Guides ---
" let g:indent_guides_enable_on_vim_startup = 1
" let g:indent_guides_auto_colors = 0
" let g:indent_guides_color_change_percent = 3 " for auto options left 5 percent only

if g:vimmode != 3
  "color form solarized8
  if g:vimTheme == 1
    autocmd VimEnter,Colorscheme * :hi IndentGuidesOdd  guibg=#002b36 ctermbg=3
    autocmd VimEnter,Colorscheme * :hi IndentGuidesEven guibg=#073642 ctermbg=4
  elseif g:vimTheme == 2
    autocmd VimEnter,Colorscheme * :hi IndentGuidesOdd  guibg=#282828 ctermbg=3
    autocmd VimEnter,Colorscheme * :hi IndentGuidesEven  guibg=#232323 ctermbg=4
    " autocmd VimEnter,Colorscheme * :hi IndentGuidesEven guibg=#3c3836 ctermbg=4
  endif
endif

" --- Vim Test ---
let g:test#strategy = 'neovim'

" --- Svelte filetypes specific ---
if !exists('g:context_filetype#filetypes')
  let g:context_filetype#filetypes = {}
endif
let g:context_filetype#filetypes.svelte =
  \ [
  \ {'filetype' : 'javascript', 'start' : '<script>', 'end' : '</script>'}
  \ ,{'filetype' : 'css', 'start' : '<style>', 'end' : '</style>'}
  \ ]

if !exists('g:context_filetype#same_filetypes')
  let g:context_filetype#same_filetypes = {}
endif
let g:context_filetype#same_filetypes.svelte = 'html'

au! BufNewFile,BufRead *.svelte set ft=html

" --- EMMET specific ---
let g:user_emmet_install_global = 0
let g:user_emmet_leader_key = ','
autocmd FileType html,css EmmetInstall

" --- PowerShell specific ---
" moved to powershell.vim

" --- vimWiki specific ---
let wikis = [
  \ {'path': '~/vimwiki/', 'syntax': 'markdown', 'ext': '.md'}
  \]

" if g:computerName =='DESKTOP-HSRFLH5' "LEGO desktop
"   add(wikis ,{'path': '~/OneDrive - LEGO/vimwiki_LEGO/', 'syntax': 'markdown', 'ext': '.md'})
" endif

let g:vimwiki_markdown_link_ext = 1
let g:vimwiki_list = wikis
let g:vimwiki_listsyms = ' –x'
let g:vimwiki_listsym_rejected = 'x'
let g:vimwiki_folding = 'list'
let g:vimwiki_key_mappings = { 'table_mappings': 0 } "! - to fix/change completion behavior

" --- VimWhichKey ---
set timeoutlen=500
if g:vimmode != 3

  call which_key#register('<Space>', "g:which_key_map")
  nnoremap <silent><space> :WhichKey ' '<CR>
  " moved before bindigs
  " let g:which_key_use_floating_win = 1 "make as floating window
  " let g:which_key_run_map_on_popup = 1

endif

" --- LUA LSP 0.5
if g:vimmode == 3
  source ~/dotfiles/nvim/plugins/nvim/lualegacy.vim
endif

function! RecurseForPath(dict,skey)
  for key in keys(a:dict)
    if type(a:dict[key]) == type({})
      call RecurseForPath(a:dict[key],a:skey.key)
    else
      if key != 'name'
      endif
    endif
  endfor
endfunction

