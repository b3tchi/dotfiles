if &compatible
  set nocompatible
endif

" Required:
" let useCoc = 1
let lspClient = 1 "1 for coc-nvim, 2 for deoplete (WIP), -1 non Lsp Client (TBD)
let vimTheme = 2 "1 solarized8, 2 gruvbox

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

" Run PlugInstall if there are missing plugins
autocmd VimEnter * if len(filter(values(g:plugs), '!isdirectory(v:val.dir)'))
  \| PlugInstall --sync | source $MYVIMRC
\| endif


" Required
call plug#begin(expand('~/.vim/plugged'))
" call plug#begin()


  ""General Vim Plugins
  Plug 'jeffkreeftmeijer/vim-numbertoggle'		"hybrid/static number toggle when multiple windows
  Plug 'google/vim-searchindex'
  Plug 'mhinz/vim-startify' "fancty start screen for VIM and session manager
  Plug 'embear/vim-localvimrc' "loading rootfolder placed vim configs /.lvimrc
  Plug 'ryanoasis/vim-devicons' "nerd fonts icons
  ""Searching fzf
  " Plug 'junegunn/fzf', {'build': './install --all', 'merged': 0}
  " Plug 'junegunn/fzf.vim', {'depends': 'fzf'}
  Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
  Plug 'junegunn/fzf.vim'
  Plug 'jesseleite/vim-agriculture' "adding option for :RgRaw to run raw commands
  " Plug 'jremmen/vim-ripgrep' "testing ripgrep single addin :Rg in fzf seems broken

  ""Status Line
  Plug 'itchyny/lightline.vim'
  Plug 'mengelbrecht/lightline-bufferline'

  "" White Space Highlighter
  Plug 'ntpeters/vim-better-whitespace'

  ""Autoclosing pairs""
  Plug 'cohama/lexima.vim'
  Plug 'editorconfig/editorconfig-vim' " not used to be investigated
  Plug 'tpope/vim-surround' "surrounding words with symbols
  "Plug 'tmsvg/pear-tree' "getting some issues for the function disabled


  "git
  Plug 'tpope/vim-fugitive' "git intergration
  Plug 'airblade/vim-gitgutter' "git intergration
  Plug 'idanarye/vim-merginal' "git branch management TUI
  Plug 'rbong/vim-flog' "git tree
  " Plug 'junegunn/gv.vim' "git tree - simplier version of flog
  " Plug 'gregsexton/gitv', {'on': ['Gitv']}
  Plug 'powerman/vim-plugin-AnsiEsc'

  ""markdown
  Plug 'vim-pandoc/vim-pandoc-syntax'
  Plug 'tpope/vim-markdown'

  " Plug 'godlygeek/tabular'

  ""vimwiki - personal notes
  " Plug 'vimwiki/vimwiki'
  " Plug 'fcpg/vim-waikiki'
  Plug 'mmai/vim-markdown-wiki'

  Plug 'dhruvasagar/vim-table-mode'

  ""addvanced ide features
  if lspClient == 1
    " Plug 'neoclide/coc.nvim', {'merge': 0, 'rev': 'release'}
    Plug 'neoclide/coc.nvim', {'branch': 'release'}
    Plug 'liuchengxu/vista.vim'
    Plug 'antoinemadec/coc-fzf', {'branch': 'release'}
    " Plug 'neoclide/coc.nvim', {'do': 'yarn install --frozen-lockfile'}
    " Plug 'neoclide/coc.nvim', {'merge':0, 'build': './install.sh nightly'}
    " Plug 'mgedmin/python-imports.vim', { 'on_ft' : 'python' }
  " elseif lspClient == 2
  "   Plug 'Shougo/deoplete.nvim'
  "   if !has('nvim')
  "     Plug 'roxma/nvim-yarp'
  "     Plug 'roxma/vim-hug-neovim-rpc'
  "   endif
  "   let g:deoplete#enable_at_startup = 1
  "   Plug 'dense-analysis/ale'
  endif

  " Svelte
  Plug 'evanleck/vim-svelte'
  Plug 'mattn/emmet-vim'

  " Support for comments symbol by language regions Svelte & Html
  Plug 'Shougo/context_filetype.vim' "language regions in files
  " Plug 'tyru/caw.vim' "comments with context regions
  " Plug 'b3tchi/caw.vim' "comments with context regions addition for svelte TEST
  " Plug 'scrooloose/nerdcommenter'
  " Plug 'tpope/vim-commentary' "comments gcc

  "Window management SuckLess
  Plug 'fabi1cazenave/suckless.vim'

  "Tmux
  Plug 'christoomey/vim-tmux-navigator'
  Plug 'preservim/vimux'
  " Plug 'christoomey/vim-tmux-runner' alternative to vimux

  "syntax highlighting
  Plug 'sheerun/vim-polyglot'

  "install dap for vim
  Plug 'puremourning/vimspector'

  "" Old Addins TBD
  "Plug 'janko-m/vim-test'
  "Plug 'neomake/neomake'

  " Adding dadbod for databases
  Plug 'tpope/vim-dadbod'
  Plug 'kristijanhusak/vim-dadbod-ui'
  Plug 'kristijanhusak/vim-dadbod-completion'

  "Run command async
  Plug 'skywind3000/asyncrun.vim'

  " themes
  Plug 'lifepillar/vim-solarized8'
  Plug 'morhetz/gruvbox'
  " Plug 'kaicataldo/material.vim'
  " Plug 'altercation/vim-colors-solarized'
  " Plug 'iCyMind/NeoSolarized'

  " vimmode 3 => Neovim 0.5+ with lua
  if g:vimmode == 3

    Plug 'neovim/nvim-lspconfig' "offical NeoVim LSP plugin
    Plug 'williamboman/nvim-lsp-installer' "automatic installer of LSPs
    " LSP List [https://github.com/neovim/nvim-lspconfig/blob/master/CONFIG.md#svelte]

    " Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'} "LSP based highlighting
    "to fix the iisue with slow markdown
    "https://github.com/nvim-treesitter/nvim-treesitter/issues/2206
    Plug 'nvim-treesitter/nvim-treesitter', {'commit': '8ada8faf2fd5a74cc73090ec856fa88f34cd364b', 'do': ':TSUpdate'}
    Plug 'nvim-lua/popup.nvim'
    Plug 'nvim-lua/plenary.nvim'
    Plug 'nvim-telescope/telescope.nvim'
    Plug 'nvim-telescope/telescope-fzf-native.nvim' "", { 'do': 'make' }

    " git
    Plug 'sindrets/diffview.nvim'

    "outlines
    Plug 'simrat39/symbols-outline.nvim' "outlines
    Plug 'nvim-orgmode/orgmode'

    ""completion
    Plug 'hrsh7th/nvim-cmp'
    Plug 'hrsh7th/cmp-nvim-lsp'

    ""Indent guides
    Plug 'lukas-reineke/indent-blankline.nvim'

    ""Treesitter backed comments
    Plug 'numToStr/Comment.nvim'
    " Plug 'waylonwalker/Telegraph.nvim' "interesting idea simple using vimux nox

    "lua extended version of which key
    Plug 'folke/which-key.nvim'

    Plug 'mfussenegger/nvim-dap'

  else

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
  endif

call plug#end()

" Required:
syntax on
" filetype plugin indent on
set noshowmode " INSERT déjà affiché par lightbar

autocmd FileType vista,coc-explorer setlocal signcolumn=no

if lspClient == 1
  source ~/.config/nvim/coc.vim
" elseif lspClient == 2
  " source ~/.config/nvim/deoplete.vim
endif

source ~/.config/nvim/incubator.vim

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

"" Define folding
set foldmethod=indent
" set foldmethod=syntax
set foldignore=
set tabstop=2
set softtabstop=2
set expandtab
set shiftwidth=2
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
if vimTheme == 1
  set termguicolors
  set background=dark
  colorscheme solarized8
"" gruvbox theme
elseif vimTheme == 2
  set termguicolors
  set background=dark
  let g:gruvbox_italic=1
  colorscheme gruvbox
  highlight Folded guibg=#232323
endif


" hi Normal guibg=NONE
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

let g:which_key_map =  {}
let g:which_key_map.b = '+buffer'

" nnoremap <C-p> :GFiles<cr>
" nnoremap <C-f> :Rg<cr>
nnoremap <silent> <space>f :Rg<cr>
nnoremap <silent> <space>b :Buffer<cr>
nnoremap <silent> ; :Buffer<cr>
nnoremap <silent> <space>e :call FuzzyFiles()<cr>
nnoremap <silent> <space>W :Windows<cr>

function FuzzyFiles()
  if get(b:,'git_dir') == 0
    exe ':FzfFiles'
  else
    exe ':GFiles'
  endif
endfunction

" source ~/dotfiles/nvim/fugidiff.vim
source ~/.config/nvim/fugidiff.vim

autocmd FileType fugitive nmap <buffer> j ):call DiffTog(1)<cr>
autocmd FileType fugitive nmap <buffer> k (:call DiffTog(1)<cr>
autocmd FileType fugitive nmap <buffer><silent> dd :call DiffTog(0)<CR>
autocmd FileType fugitive nmap <buffer><silent> l :call NextChange()<CR>
autocmd FileType fugitive nmap <buffer><silent> h :call PrevChange()<CR>

let g:which_key_map.g ={'name':'+git'}
let g:which_key_map.g.g = 'fugitive'
nnoremap <silent> <space>gg :tab G<cr>
let g:which_key_map.g.C = 'commit&push'
nnoremap <space>gC :w \| :G commit -a -m '' \| :G push<left><left><left><left><left><left><left><left><left><left><left>
let g:which_key_map.g.c = 'commit'
nnoremap <space>gc :G commit -m ''<left>
let g:which_key_map.g.p = 'pull'
nnoremap <silent> <space>gp :G pull<cr>
let g:which_key_map.g.P = 'push'
nnoremap <silent> <space>gP :G push<cr>
let g:which_key_map.g.f = 'fetch'
nnoremap <silent> <space>gf :G fetch<cr>
let g:which_key_map.g.m = 'merge'
nnoremap <silent> <space>gm :G merge<cr>
let g:which_key_map.g.l = 'log'
nnoremap <silent> <space>gl :Flog -format=%>\|(65)\ %>(65)\ %<(40,trunc)%s\ %>\|(120%)%ad\ %an%d -date=short<cr>


"dadbod UI
let g:db_ui_disable_mappings = 1
let g:which_key_map.d ={'name':'+dadbod-ui'}
autocmd FileType sql nmap <buffer><silent><space>de <Plug>(DBUI_ExecuteQuery)
let g:which_key_map.d.e = 'execute query'
autocmd FileType sql nmap <buffer><silent><space>dw <Plug>(DBUI_SaveQuery)
let g:which_key_map.d.s = 'save query'

autocmd FileType dbui nmap <buffer> <S-k> <Plug>(DBUI_GotoFirstSibling)
autocmd FileType dbui nmap <buffer> <S-j> <Plug>(DBUI_GotoLastSibling)
" autocmd FileType dbui nmap <buffer> k <Plug>(DBUI_GotoPrevSibling)
" autocmd FileType dbui nmap <buffer> j <Plug>(DBUI_GotoNextSibling)


nnoremap <space>dn :DBUIToggle<CR>
let g:which_key_map.d.n = 'navpane'
nnoremap <space>dh :help DBUI<CR>
let g:which_key_map.d.h = 'help'

" autocmd FileType dbui nmap <buffer> <C-k> <c-w>W
" autocmd FileType dbui nmap <buffer> <C-j> <c-w>w

" nnoremap <space>de ,S
" autocmd FileType sql nmap <buffer> <space>de <Plug>(DBUI_ExecuteQuery)
"tasks TBD
nnoremap <silent> <space>tn :Trep<cr>

"Incubator.vim
" nnoremap <silent>  k :call <SID>incubator.vim#ToggleOnTerminal('J', 6)<CR>

let g:which_key_map.v ={'name':'+vim'}
nnoremap <silent> <space>vk :Maps<cr>
let g:which_key_map.v.h ={'name':'+help'}
nnoremap <silent> <space>vhf :Helptags<cr>

let g:which_key_map.v.p ={'name':'+plug'}
nnoremap <silent> <space>vpu :PlugUpdate<cr>
nnoremap <silent> <space>vpi :PlugStatus<cr>

let g:which_key_map.v.c ={'name':'+coc'}
nnoremap <silent> <space>vcu :CocUpdate<cr>

let g:which_key_map.v.i ={'name':'+init.vim'}
nnoremap <space>viu :source ~/.config/nvim/init.vim<cr>:LightlineReload<cr>

let g:which_key_map.c ={'name':'+console'}
" let g:VimuxRunnerName = "vimuxout"
let g:VimuxRunnerType = "pane"
function! VimuxSlime()
  call VimuxRunCommand(@v, 0)
  " echom @v
endfunction

function! VimuxMdBlock()
   let mdblock = MarkdownBlock()
   "  if mdblock.lang == 'bash'

   "bash command
   if index(['bash','sh'],mdblock.lang) > -1
     let lines = join(mdblock.code, "\n") . "\n"
     call VimuxRunCommand(lines)

   "powershell
   elseif index(['pwsh','ps','powershell'],mdblock.lang) > -1
     " let tmp = tempname()
     " call writefile(mdblock.code, tmp)
     " call VimuxRunCommand('powershell.exe '.tmp)
     " call delete(tmp)

     "rand filename
      let fname = tempname()
      let fname = substitute(fname,'/','','g') . '.ps1'

      "paths
      let win_tmpps = trim(system('cd /mnt/c/ && cmd.exe /c echo %TEMP% && cd - | grep C: ')) . '\'
      let unx_tmpps = substitute(win_tmpps,'\\','/','g')
      let unx_tmpps = substitute(unx_tmpps,'C:','/mnt/c','g')
      ""let unx_tmpps = '/mnt/c/Users/czJaBeck/AppData/Local/Temp/' . fname
      let win_tmpps = win_tmpps . fname
      let unx_tmpps = unx_tmpps . fname
      " echom win_tmpps
      " echom unx_tmpps
      call writefile(mdblock.code, unx_tmpps)

      let cmd = 'powershell.exe ''' . win_tmpps . ''''
      call VimuxRunCommand(cmd)


   "wimscript
 elseif index(['vim','viml'],mdblock.lang) > -1
     let lines = mdblock.code
     let tmp = tempname()
     call writefile(lines, tmp)
     exec 'source '.tmp
     call delete(tmp)
   endif
endfunction

function! MarkdownBlock()
  let view = winsaveview()
  let line = line('.')
  let cpos = getpos('.')
  let start = search('^\s*[`~]\{3,}\S*\s*$', 'bnW')
  if !start
    return
  endif

  call cursor(start, 1)
  let [fence, langv] = matchlist(getline(start), '\([`~]\{3,}\)\(\S\+\)\?')[1:2]
  let end = search('^\s*' . fence . '\s*$', 'nW')

  if end < line""|| langidx < 0
    call winrestview(view)
    return
  endif

  let resp = {}
  let resp.code = getline(start + 1, end - 1) ""block"" list2str(block)
  let resp.lang = langv
  call setpos('.',cpos)
  return resp
endfunction

nnoremap <silent> <space>co :VimuxOpenRunner<cr>
nnoremap <silent> <space>cq :VimuxCloseRunner<cr>
nnoremap <silent> <space>cl :VimuxRunLastCommand<cr>
nnoremap <silent> <space>cx :VimuxInteruptRunner<cr>
nnoremap <silent> <space>ci :VimuxInspectRunner<CR>
nnoremap <silent> <space>cp :VimuxPromptCommand<CR>
nnoremap <silent> <space>cr vip "vy :call VimuxSlime()<CR>
nnoremap <silent> <space>cb :call VimuxMdBlock()<CR>

" nnoremap <space>cz :lua require'telegraph'.telegraph({how='tmux_popup', cmd='man '})<Left><Left><Left>

vmap <space>cr "vy :call VimuxSlime()<CR>

let g:which_key_map.v.l ={'name':'+lsp'}
nnoremap <silent> <space>vli :LspInstallInfo<cr>
 " If text is selected, save it in the v buffer and send that buffer it to tmux


let g:which_key_map.v.l ={'name':'+sessions'}
nnoremap <silent> <space>ss :SSave<cr>
nnoremap <silent> <space>sd :SDelete<cr>
nnoremap <silent> <space>sc :SClose<cr>

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

" --- DadBod UI ---
let g:db_ui_disable_mappings = 1

autocmd FileType sql nmap <buffer><silent><space>de <Plug>(DBUI_ExecuteQuery)
autocmd FileType sql nmap <buffer><silent><space>dw <Plug>(DBUI_SaveQuery)

autocmd FileType dbui nmap <buffer> <S-k> <Plug>(DBUI_GotoFirstSibling)
autocmd FileType dbui nmap <buffer> <S-j> <Plug>(DBUI_GotoLastSibling)
autocmd FileType dbui nmap <buffer> k <up>
autocmd FileType dbui nmap <buffer> j <down>
" autocmd FileType dbui nmap <buffer> k <Plug>(DBUI_GotoPrevSibling)
" autocmd FileType dbui nmap <buffer> j <Plug>(DBUI_GotoNextSibling)
autocmd FileType dbui nmap <buffer> A <Plug>(DBUI_AddConnection)
autocmd FileType dbui nmap <buffer> r <Plug>(DBUI_RenameLine)
autocmd FileType dbui nmap <buffer> h <Plug>(DBUI_GotoParentNode)
autocmd FileType dbui nmap <buffer> o <Plug>(DBUI_SelectLine)
autocmd FileType dbui nmap <buffer> l <Plug>(DBUI_GotoChildNode)

nnoremap <space>dn :DBUIToggle<CR>

" --- Better White Space
let g:better_whitespace_filetypes_blacklist = [
  \ 'dbout'
  \ ]

" --- Vim Wiki ---
nnoremap <silent><space>Wt :VimwikiTable 1 2


" --- Coc ---
if lspClient == 1
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
  nnoremap <silent> <space>O :Vista!!<CR>
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
endif

nnoremap <Tab> :bnext!<CR>
nnoremap <S-Tab> :bprev!<CR>

nnoremap <C-Tab> :bnext!<CR>
nnoremap <S-C-Tab> :bprev!<CR>

inoremap <expr><S-TAB> pumvisible() ? "\<C-p>" : "\<C-h>"
inoremap <expr><C-S-Space> pumvisible() ? "\<C-p>" : "\<C-h>"

" tmap <S-TAB> <Nop>
" tmap <TAB> <Nop>

inoremap <expr> <cr> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"
" inoremap <expr> <CR> pumvisible() ? "\<C-y>" : "\<CR>"
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

" --- lightline ---
source ~/.config/nvim/lightline.vim
"
" function LightlineFilename()
"   let root = fnamemodify(get(b:, 'git_dir'), ':h')
"   "split join for replace different separators in Windows dirty fix
"   let path = join(split(expand('%:p'),'\'),'/')
"   if path[:len(root)-1] ==# root
"     return path[len(root)+1:]
"   endif
"   return expand('%')
" endfunction
"
"--- Vista --- NEEDED similar as coclist as outline
"PROBABLY TBR succed by fzf-coc
let g:vista_default_executive = 'coc'
let g:vista#renderer#enable_icon = 1
let g:vista#renderer#icons = {
  \   "function": "\uf794",
  \   "variable": "\uf71b",
  \  }
" let g:vista_icon_indent = ["▸ ", ""]
let g:vista_icon_indent = ["", ""] " kept emtpy using iguides
"g:vista_echo_cursor_strategy = 'both'

" --- fzf ---
"to fix issue added this to bash
"export FZF_DEFAULT_COMMAND="rg --files --hidden --follow --glob '!.git'"

let $FZF_DEFAULT_OPTS = '--reverse'
let $FZF_DEFAULT_COMMAND = 'rg --files --hidden --follow --glob ''!.git'''
let $BAT_THEME = 'gruvbox' "need bat 16.0 and higher
" let $BAT_THEME = 'OneHalfDark'

let g:rg_derive_root='true'
let g:fzf_layout = { 'window': 'call OpenFloatingWin()' }
" let g:fzf_layout = { 'window': {'width': 0.95, 'height': 0.95} }
" let g:fzf_preview_window = ['down:40%:hidden', 'ctrl-/']
let g:fzf_preview_window = ['right:40%:hidden', 'ctrl-/']

" function! PreviewIfWide(spec)
"   return &columns < 120 ? fzf#vim#with_preview(a:spec) : a:spec
" endfunction

function! PreviewIfWide2()
  return &columns < 120 ? fzf#vim#with_preview('up:40%', 'ctrl-/') :fzf#vim#with_preview('right:40%', 'ctrl-/')
endfunction

command! -bang -nargs=? -complete=dir FzfFiles
  \ call fzf#vim#files(
  \ <q-args>,
  \ PreviewIfWide2(),
  \ <bang>0)

" Shouldn't be needed https://medium.com/@sidneyliebrand/how-fzf-and-ripgrep-improved-my-workflow-61c7ca212861
" command! -bang -nargs=* Rg
"   \ call fzf#vim#grep(
"   \   'rg'
"   \   , 1
"   \   ,<bang>0 ? fzf#vim#with_preview() : fzf#vim#with_preview()
"   \   ,<bang>0
"   \   )
"   \   'rg --column --line-number --no-heading --fixed-strings --color=always --glob "!.git/*" --smart-case '.shellescape(<q-args>)
"adjusting ripgrep command TBD project root

command! -bang -nargs=* Trep
  \ call fzf#vim#grep(
  \   'rg --column --hidden --line-number --no-heading --color=always --glob "!.git/*" --smart-case ' - \[ \]"', 1,
  \   PreviewIfWide2(),
  \   <bang>0)

"adjusting ripgrep command TBD project root
command! -bang -nargs=* Rg
  \ call fzf#vim#grep(
  \   'rg --column --line-number --no-heading --color=always --glob "!.git/*" --smart-case '.shellescape(<q-args>), 1,
  \   PreviewIfWide2(),
  \   <bang>0)

command! -bang -nargs=? -complete=dir GFiles
  \ call fzf#vim#gitfiles(
  \   <q-args>,
  \   PreviewIfWide2(),
  \   <bang>0)

command! -bang -nargs=* Hx
  \ call fzf#vim#grep(
  \   'rg --column --line-number --hidden --no-heading --color=always --glob "**/plugged/**/doc/**.txt" --smart-case "(?:^.*[*])(.*)(?:[*]$)" "/home/jan/" ', 1,
  \   PreviewIfWide2(),
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
highlight Comment cterm=italic


"--- startify --- TODO
" let g:startify_bookmarks = ['~/svn', '~/dev']
autocmd User StartifyAllBuffersOpened call SetNeovimTitle()
autocmd User StartifyBufferOpened call SetNeovimTitle()

" set title - required this option to be on - in general settings above
function! SetNeovimTitle()
  let g:test2 = fnamemodify(v:this_session, ':t')
  let &titlestring = fnamemodify(v:this_session, ':t')

endfunction

let g:startify_lists = [
  \ { 'type': 'sessions',  'header': ['   Sessions']       },
  \ { 'type': 'files',     'header': ['   MRU']            },
  \ { 'type': 'dir',       'header': ['   MRU '. getcwd()] },
  \ { 'type': 'bookmarks', 'header': ['   Bookmarks']      },
  \ { 'type': 'commands',  'header': ['   Commands']       },
  \ ]

"--- Indent Guides ---
" let g:indent_guides_enable_on_vim_startup = 1
" let g:indent_guides_auto_colors = 0
" let g:indent_guides_color_change_percent = 3 " for auto options left 5 percent only

if g:vimmode != 3
  "color form solarized8
  if vimTheme == 1
    autocmd VimEnter,Colorscheme * :hi IndentGuidesOdd  guibg=#002b36 ctermbg=3
    autocmd VimEnter,Colorscheme * :hi IndentGuidesEven guibg=#073642 ctermbg=4
  elseif vimTheme == 2
    autocmd VimEnter,Colorscheme * :hi IndentGuidesOdd  guibg=#282828 ctermbg=3
    autocmd VimEnter,Colorscheme * :hi IndentGuidesEven  guibg=#232323 ctermbg=4
    " autocmd VimEnter,Colorscheme * :hi IndentGuidesEven guibg=#3c3836 ctermbg=4
  endif
endif

"--- Indent Line ---
" let g:indentLine_char               = "⎸"
" let g:indentLine_faster             = 1
" let g:indentLine_fileTypeExclude    = ['json',  'startify', '', 'help', 'coc-explorer']
" let g:indentLine_setConceal = 1
" set conceallevel=1
" let g:indentLine_conceallevel=1
"--- not used ---
" let g:indentLine_leadingSpaceEnabled = 1
" let g:indentLine_leadingSpaceChar   = '·'
" --- VimSpector ---
nnoremap <space>ud :call vimspector#Launch()<CR>
nnoremap <space>uq :call vimspector#Reset()<CR>
nnoremap <space>uc :call vimspector#Continue()<CR>

nnoremap <space>ut :call vimspector#ToggleBreakpoint()<CR>
nnoremap <space>uT :call vimspector#ClearBreakpoints()<CR>

nmap <space>uk <Plug>VimspectorRestart
nmap <space>uh <Plug>VimspectorStepOut
nmap <space>ul <Plug>VimspectorStepInto
nmap <space>uj <Plug>VimspectorStepOver

" --- Vim Test ---
let g:test#strategy = 'neovim'

" --- Markdown specific ---
let g:markdown_fenced_languages = ['coffee', 'css', 'erb=eruby', 'javascript', 'js=javascript', 'json=javascript', 'ruby', 'sass','sh=bash','bash', 'vim', 'xml']

function! Mdftinit()
  setlocal spell spelllang=en_us
  " set filetype=markdown.pandoc
  let g:pandoc#syntax#codeblocks#embeds#langs = ["vim=vim"]
  " echom 'loade nmd'
endfunction
augroup pandoc_syntax
  au! BufNewFile,BufFilePre,BufRead *.md call Mdftinit()
  " autocmd! FileType vimwiki set syntax=markdown.pandoc
augroup END

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
" powershell 200831 not regnized set manually
au! BufNewFile,BufRead *.ps1 set ft=ps1

" --- vimWiki specific ---
let wikis = [
  \ {'path': '~/vimwiki/', 'syntax': 'markdown', 'ext': '.md'}
  \]

if g:computerName =='DESKTOP-HSRFLH5' "LEGO desktop
  add(wikis ,{'path': '~/OneDrive - LEGO/vimwiki_LEGO/', 'syntax': 'markdown', 'ext': '.md'})
endif

let g:vimwiki_markdown_link_ext = 1
let g:vimwiki_list = wikis
let g:vimwiki_listsyms = ' –x'
let g:vimwiki_listsym_rejected = 'x'
let g:viswiki_folding = 'list'
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
  source ~/.config/nvim/lualsp.vim
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

