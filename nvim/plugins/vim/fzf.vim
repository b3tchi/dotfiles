  Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
  Plug 'junegunn/fzf.vim'

  " Plug 'junegunn/fzf', {'build': './install --all', 'merged': 0}
  " Plug 'junegunn/fzf.vim', {'depends': 'fzf'}
"to fix issue added this to bash
"export FZF_DEFAULT_COMMAND="rg --files --hidden --follow --glob '!.git'"

let $FZF_DEFAULT_OPTS = '--reverse'
let $FZF_DEFAULT_COMMAND = 'rg --files --hidden --follow --glob ''!.git'''

function LoadedFzf()
  " echom "gruvRun"

function FuzzyFiles()
  if get(b:,'git_dir') == 0
    exe ':FzfFiles'
  else
    exe ':GFiles'
  endif
endfunction

nnoremap <silent> <space>ee :call FuzzyFiles()<cr>

" nnoremap <silent> <space>bb :Buffers<cr>
nnoremap <silent> <space>ww :Windows<cr>
nnoremap <silent> <space>tn :Trep<cr>
nnoremap <silent> <space>ff :Rg<cr>
nnoremap <silent> <space>vk :Maps<cr>

" nnoremap <silent> <space>vhf :Helptags<cr>
let g:fzf_layout = { 'window': 'call OpenFloatingWin()' }
" let g:fzf_layout = { 'window': {'width': 0.95, 'height': 0.95} }
" let g:fzf_preview_window = ['down:40%:hidden', 'ctrl-/']

let g:fzf_preview_window = ['right:40%:hidden', 'ctrl-/']
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
endfunction

augroup LoadedFzf
  autocmd!
  autocmd User PlugLoaded call LoadedFzf()
augroup END
