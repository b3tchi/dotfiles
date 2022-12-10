if &compatible
  set nocompatible
endif

" Required:
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

""decide what is vim model, 1 vim, pre-0.5 nvim, 0.5+ nvim
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
" echom "plugbegin"


  ""General Vim Plugins
  Plug 'jeffkreeftmeijer/vim-numbertoggle'		"hybrid/static number toggle when multiple windows
  " Plug 'google/vim-searchindex'
  " Plug 'embear/vim-localvimrc' "loading rootfolder placed vim configs /.lvimrc
  " Plug 'ryanoasis/vim-devicons' "nerd fonts icons

  ""Welcome & Session Management
  " source ~/dotfiles/nvim/plugins/vim/startify.vim

  ""Searching fzf
  source ~/dotfiles/nvim/plugins/vim/fzf.vim

  " Plug 'jesseleite/vim-agriculture' "adding option for :RgRaw to run raw commands
  " Plug 'jremmen/vim-ripgrep' "testing ripgrep single addin :Rg in fzf seems broken

  "" White Space Highlighter
  Plug 'ntpeters/vim-better-whitespace'

  ""Autoclosing pairs""
  " Plug 'cohama/lexima.vim'
  " Plug 'editorconfig/editorconfig-vim' " not used to be investigated
  " Plug 'tpope/vim-surround' "surrounding words with symbols
  "Plug 'tmsvg/pear-tree' "getting some issues for the function disabled

  Plug 'powerman/vim-plugin-AnsiEsc'

  " Plug 'mmai/vim-markdown-wiki'
  " Plug 'dhruvasagar/vim-table-mode'


  ""vimwiki - personal notes
  " Plug 'fcpg/vim-waikiki'

  ""addvanced ide features
  " if g:lspClient == 1
  "   source ~/dotfiles/nvim/plugins/vim/coc.vim
  " elseif g:lspClient == 2
  "   source ~/dotfiles/nvim/plugins/vim/deoplete.vim
  " endif
  "
  " Svelte
  " Plug 'evanleck/vim-svelte'
  " Plug 'mattn/emmet-vim'

  " Plug 'tyru/caw.vim' "comments with context regions
  " Plug 'b3tchi/caw.vim' "comments with context regions addition for svelte TEST
  " Plug 'scrooloose/nerdcommenter'
  " Plug 'tpope/vim-commentary' "comments gcc

  "Window management SuckLess
  " Plug 'fabi1cazenave/suckless.vim'

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
  " Plug 'skywind3000/asyncrun.vim'

  "Git
  source ~/dotfiles/nvim/plugins/vim/git.vim

  " vimmode 3 => Neovim 0.5+ with lua
  if g:vimmode == 3

    " syntax and grammatics TBR should be within modules where it's needed
    " Plug 'nvim-lua/popup.nvim'
    " Plug 'nvim-lua/plenary.nvim'
    "
    source ~/dotfiles/nvim/plugins/nvim/sessionsmgr.lua "migratting sessions from startifu
    "LANGUAGE SERVER
    "language server implementation
    source ~/dotfiles/nvim/plugins/nvim/lualsp.vim "general lsp settings
    source ~/dotfiles/nvim/plugins/nvim/troublenvim.lua "dignostics improvements
    source ~/dotfiles/nvim/plugins/nvim/mason.vim "nvim-lsp-installer mk.2
    "
    " "SYNTAX HIGHLIGHT
    source ~/dotfiles/nvim/plugins/nvim/treesitter.vim "syntax highlight support
    source ~/dotfiles/nvim/plugins/nvim/hicolors.lua "highlight colors in the code
    source ~/dotfiles/nvim/plugins/nvim/headlines.vim "nice headlines
    "
    " "CODE ACTIONS
    source ~/dotfiles/nvim/plugins/nvim/commentnvim.lua "code commenting

    "THEME
    " themes have to be before lualine
    if luaeval('vim.env.THEME') == 'gruvbox'
        source ~/dotfiles/nvim/themes/gruvbox.lua
    elseif luaeval('vim.env.THEME') == 'tokionight'
        source ~/dotfiles/nvim/themes/tokionight.lua
    endif

    " "USER INTERFACE
    source ~/dotfiles/nvim/plugins/nvim/telescope.vim "search pop-up window
    source ~/dotfiles/nvim/plugins/nvim/whichkey.lua "key maps preview
    source ~/dotfiles/nvim/plugins/nvim/nvmcmp.vim "completion
    " "
    source ~/dotfiles/nvim/plugins/nvim/foldufo.vim "code folding
    source ~/dotfiles/nvim/plugins/nvim/indentblankline.lua "indent guides
    source ~/dotfiles/nvim/plugins/nvim/scrollbar.vim "scrollbar
    "
    source ~/dotfiles/nvim/plugins/nvim/symbolsoutline.lua "outlines panel
    source ~/dotfiles/nvim/plugins/nvim/neotree.vim "file panel
    source ~/dotfiles/nvim/plugins/nvim/heirline.lua "bars setup (statusbar,winbar,tabbar)
    source ~/dotfiles/nvim/plugins/nvim/noicenvim.lua "notifications and commandline input location

    " source ~/dotfiles/nvim/plugins/nvim/nvimtree.vim "file panel
    " source ~/dotfiles/nvim/plugins/nvim/lualine.vim "Status luaLine
    " source ~/dotfiles/nvim/plugins/nvim/bufferline.vim
    " source ~/dotfiles/nvim/plugins/nvim/barbar.vim "Status bufferline

    "LANGUAGE SPECIFIC
    source ~/dotfiles/nvim/plugins/nvim/orgmode.lua "orgmode
    source ~/dotfiles/nvim/plugins/nvim/mdpreview.vim "markdown files
    " source ~/dotfiles/nvim/plugins/nvim/telekasten.vim will try orgmode
    "
    " "VERSION CONTROL
    source ~/dotfiles/nvim/plugins/nvim/diffview.lua "addvanced diffview
    source ~/dotfiles/nvim/plugins/nvim/gitsigns.lua "signs for changes
    source ~/dotfiles/nvim/plugins/nvim/octonvim.lua "gh cli integration
    "
    " "OTHER
    source ~/dotfiles/nvim/plugins/nvim/nvimdap.vim "debugging
    source ~/dotfiles/nvim/plugins/nvim/hydra.vim "custom modes
    source ~/dotfiles/nvim/plugins/nvim/luapad.lua "lua scratchpad

  endif

call plug#end()

" Run PlugInstall if there are missing plugins
if len(filter(values(g:plugs), '!isdirectory(v:val.dir)'))
  PlugInstall --sync ""| source $MYVIMRC
endif

" echom "plugend"
"event triggering after plug
doautocmd User PlugLoaded
" echo "plugafterevent"

" Allow gf to open non-existent files
map gf :edit <cfile><cr>

" Required:
syntax on
" filetype plugin indent on
set noshowmode " INSERT déjà affiché par lightbar


"languages
source ~/dotfiles/nvim/languages/bash.lua
source ~/dotfiles/nvim/languages/svelte.vim
source ~/dotfiles/nvim/languages/yaml.lua
source ~/dotfiles/nvim/languages/powershell.vim "ENABLED TESTING mason
source ~/dotfiles/nvim/languages/csharp.vim
source ~/dotfiles/nvim/languages/terraform.lua
source ~/dotfiles/nvim/languages/typescript.vim
source ~/dotfiles/nvim/languages/otherlangs.lua

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
set fillchars+=diff:╱,vert:┃ " for vsplits

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

set signcolumn=auto:4 "always show signcolumns up to 4 positions
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

function SynStack()
  if !exists("*synstack")
    return
  endif
  echo map(synstack(line('.'), col('.')), 'synIDattr(v:val, "name")')
endfunc

nnoremap <silent> <space>bh :call SynStack()<cr>
" -----------------------------
" --------- Shortcuts ---------
" -----------------------------{{{

nnoremap <C-C> <C-[>

let g:which_key_map.b = '+buffer'
nnoremap <silent> <space>bb :Telescope buffers<cr>
nnoremap <silent> <space>bs :StripWhitespace<cr>
nnoremap <silent> <space>bl :LspInfo<cr>

let g:which_key_map.v.p ={'name':'+plug'}
nnoremap <silent> <space>vpu :PlugUpdate<cr>
nnoremap <silent> <space>vpi :PlugStatus<cr>
nnoremap <silent> <space>vpc :PlugClean<cr>

let g:which_key_map.v.i ={'name':'+init.vim'}
nnoremap <space>viu :source ~/.config/nvim/init.vim<cr>

let g:which_key_map.v.l ={'name':'+lsp'}

" replace word
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

nnoremap <Tab> :bnext!<CR>
nnoremap <S-Tab> :bprev!<CR>

nnoremap <C-Tab> :bnext!<CR>
nnoremap <S-C-Tab> :bprev!<CR>

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

" --- local vimrc ---
"diable prompts on folder change
let g:localvimrc_sandbox = 0
let g:localvimrc_ask = 0

let g:rg_derive_root='true'

" --- EMMET specific ---
let g:user_emmet_install_global = 0
let g:user_emmet_leader_key = ','
autocmd FileType html,css EmmetInstall

