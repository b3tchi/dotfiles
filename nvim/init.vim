if &compatible
  set nocompatible
endif

" Required:
" let useCoc = 1
let g:lspClient = 1 "1 for coc-nvim, 2 for deoplete (WIP), -1 non Lsp Client (TBD)
let g:vimTheme = 2 "1 solarized8, 2 gruvbox

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

" Required
call plug#begin(expand('~/.vim/plugged'))
" call plug#begin()


  ""General Vim Plugins
  Plug 'jeffkreeftmeijer/vim-numbertoggle'		"hybrid/static number toggle when multiple windows
  Plug 'google/vim-searchindex'
  Plug 'embear/vim-localvimrc' "loading rootfolder placed vim configs /.lvimrc
  Plug 'ryanoasis/vim-devicons' "nerd fonts icons

  source ~/dotfiles/nvim/plugins/startify.vim

  ""Searching fzf
  source ~/dotfiles/nvim/plugins/fzf.vim

  Plug 'jesseleite/vim-agriculture' "adding option for :RgRaw to run raw commands
  " Plug 'jremmen/vim-ripgrep' "testing ripgrep single addin :Rg in fzf seems broken


  "" White Space Highlighter
  Plug 'ntpeters/vim-better-whitespace'

  ""Autoclosing pairs""
  Plug 'cohama/lexima.vim'
  Plug 'editorconfig/editorconfig-vim' " not used to be investigated
  Plug 'tpope/vim-surround' "surrounding words with symbols
  "Plug 'tmsvg/pear-tree' "getting some issues for the function disabled

  source ~/dotfiles/nvim/plugins/git.vim

  " Plug 'junegunn/gv.vim' "git tree - simplier version of flog
  " Plug 'gregsexton/gitv', {'on': ['Gitv']}
  Plug 'powerman/vim-plugin-AnsiEsc'

  ""markdown
  Plug 'vim-pandoc/vim-pandoc-syntax'
  Plug 'tpope/vim-markdown'
  Plug 'mmai/vim-markdown-wiki'
  Plug 'dhruvasagar/vim-table-mode'

  source ~/dotfiles/nvim/plugins/mdpreview.vim

  ""vimwiki - personal notes
  " Plug 'vimwiki/vimwiki'
  " Plug 'fcpg/vim-waikiki'

  ""addvanced ide features
  if g:lspClient == 1
    source ~/dotfiles/nvim/coc.vim
  " elseif g:lspClient == 2
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
  source ~/dotfiles/nvim/plugins/vimux.vim

  "syntax highlighting
  Plug 'sheerun/vim-polyglot'

  "install dap for vim
  " Plug 'puremourning/vimspector'
  " source ~/dotfiles/nvim/plugins/vimspector.vim

  "" Old Addins TBD
  "Plug 'janko-m/vim-test'
  "Plug 'neomake/neomake'

  " Adding dadbod for databases
  source ~/dotfiles/nvim/plugins/dadbod.vim

  "Run command async
  Plug 'skywind3000/asyncrun.vim'

  " themes
  source ~/dotfiles/nvim/plugins/gruvbox.vim

  " Plug 'lifepillar/vim-solarized8'
  " Plug 'morhetz/gruvbox'
  " Plug 'kaicataldo/material.vim'
  " Plug 'altercation/vim-colors-solarized'
  " Plug 'iCyMind/NeoSolarized'

  " vimmode 3 => Neovim 0.5+ with lua
  if g:vimmode == 3

    "language server implementation
    Plug 'neovim/nvim-lspconfig' "offical NeoVim LSP plugin
    Plug 'williamboman/nvim-lsp-installer' "automatic installer of LSPs
    " LSP List [https://github.com/neovim/nvim-lspconfig/blob/master/CONFIG.md#svelte]

    " syntax and grammatics
    " Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'} "LSP based highlighting
    "to fix the iisue with slow markdown
    "https://github.com/nvim-treesitter/nvim-treesitter/issues/2206
    Plug 'nvim-treesitter/nvim-treesitter', {'commit': '8ada8faf2fd5a74cc73090ec856fa88f34cd364b', 'do': ':TSUpdate'}
    Plug 'nvim-lua/popup.nvim'
    Plug 'nvim-lua/plenary.nvim'

    "telescope search instead of fzf
    Plug 'nvim-telescope/telescope.nvim'
    Plug 'nvim-telescope/telescope-fzf-native.nvim',  { 'do': 'make' }
    source ~/dotfiles/nvim/plugins/telescope.vim


    " git
    " Plug 'sindrets/diffview.nvim'
    Plug 'ThePrimeagen/git-worktree.nvim'

    "outlines
    Plug 'simrat39/symbols-outline.nvim' "outlines

    "notes taking - NOT USED to be checked
    Plug 'nvim-orgmode/orgmode'

    ""completion
    Plug 'hrsh7th/nvim-cmp'
    Plug 'hrsh7th/cmp-nvim-lsp'

    "debugger
    source ~/dotfiles/nvim/plugins/nvimdap.vim

    ""Indent guides
    Plug 'lukas-reineke/indent-blankline.nvim'

    ""Treesitter backed comments
    Plug 'numToStr/Comment.nvim'
    " Plug 'waylonwalker/Telegraph.nvim' "interesting idea simple using vimux nox

    "lua extended version of which key
    Plug 'folke/which-key.nvim'

    "scrollbar
    source ~/dotfiles/nvim/plugins/scrollbar.vim

    "Status Line & bufferline
    source ~/dotfiles/nvim/plugins/lualine.vim

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

    ""Status Line & bufferline
    source ~/dotfiles/nvim/plugins/lightline.vim
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

"TBD reorganize coc same as other files to plugin folder
if g:lspClient == 1
  source ~/.config/nvim/coc.vim
" elseif g:lspClient == 2
  " source ~/.config/nvim/deoplete.vim
endif

"languages
source ~/dotfiles/nvim/languages/bash.vim
source ~/dotfiles/nvim/languages/yaml.vim
source ~/dotfiles/nvim/languages/powershell.vim
source ~/dotfiles/nvim/languages/csharp.vim
source ~/dotfiles/nvim/languages/terraform.vim
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
" set foldmethod=indent
" set foldlevelstart=20
" highlight Folded
"
" " set foldmethod=syntax
" set foldignore=
" set tabstop=2
" set softtabstop=2
" set expandtab
" set shiftwidth=2

set nofoldenable
set foldlevel=99
set foldlevelstart=99
set fillchars=fold:\
set foldtext=CustomFoldText()
setlocal foldmethod=expr
setlocal foldexpr=GetPotionFold(v:lnum)
highlight Folded

function! GetPotionFold(lnum)
  if getline(a:lnum) =~? '\v^\s*$'
    return '-1'
  endif

  let this_indent = IndentLevel(a:lnum)
  let next_indent = IndentLevel(NextNonBlankLine(a:lnum))

  if next_indent == this_indent
    return this_indent
  elseif next_indent < this_indent
    return this_indent
  elseif next_indent > this_indent
    return '>' . next_indent
  endif
endfunction

function! IndentLevel(lnum)
    return indent(a:lnum) / &shiftwidth
endfunction

function! NextNonBlankLine(lnum)
  let numlines = line('$')
  let current = a:lnum + 1

  while current <= numlines
      if getline(current) =~? '\v\S'
          return current
      endif

      let current += 1
  endwhile

  return -2
endfunction

function! CustomFoldText()
  " get first non-blank line
  let fs = v:foldstart

  while getline(fs) =~ '^\s*$' | let fs = nextnonblank(fs + 1)
  endwhile

  if fs > v:foldend
      let line = getline(v:foldstart)
  else
      let line = substitute(getline(fs), '\t', repeat(' ', &tabstop), 'g')
  endif

  let w = winwidth(0) - &foldcolumn - (&number ? 8 : 0)
  let foldSize = 1 + v:foldend - v:foldstart
  let foldSizeStr = " " . foldSize . " lines "
  let foldLevelStr = repeat("+--", v:foldlevel)
  let expansionString = repeat(" ", w - strwidth(foldSizeStr.line.foldLevelStr))
  return line . expansionString . foldSizeStr . foldLevelStr
endfunction



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

let g:which_key_map.v.c ={'name':'+coc'}
nnoremap <silent> <space>vcu :CocUpdate<cr>

let g:which_key_map.v.i ={'name':'+init.vim'}
nnoremap <space>viu :source ~/.config/nvim/init.vim<cr>:LightlineReload<cr>

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
" moved to fzf.vim

let $BAT_THEME = 'gruvbox' "need bat 16.0 and higher
" let $BAT_THEME = 'OneHalfDark'

let g:rg_derive_root='true'

"--- NERD Commenter ---
"using tpope's commentary
" let g:NERDSpaceDelims = 1
" let g:NERDCompactSexyComs = 1
highlight Comment cterm=italic


"--- startify --- TODO
" let g:startify_bookmarks = ['~/svn', '~/dev']
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

" --- Markdown specific ---
let g:markdown_fenced_languages = ['coffee', 'css', 'erb=eruby', 'javascript', 'js=javascript', 'json=javascript', 'ruby', 'sass','sh=bash','bash', 'vim', 'xml','sql','cs']

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

