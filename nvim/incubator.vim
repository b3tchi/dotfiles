function! PutTermPanel(buf, side, size) abort
  " new term if no buffer
  if a:buf == 0
    execute "sp term://fish"
  else
    execute "sp" bufname(a:buf)
  endif

  " switch to insert mode by default
  execute "normal i"

  "window dimensions constaints

  " default side if wrong argument
  if stridx("hjklHJKL", a:side) == -1
    execute "wincmd" "J"
  else
    execute "wincmd" a:side
  endif
  " horizontal split resize
  if stridx("jkJK", a:side) >= 0
    if ! a:size > 0
      resize 6
    else
      execute "resize" a:size
    endif
    return
  endif
  " vertical split resize
  if stridx("hlHL", a:side) >= 0
    if ! a:size > 0
      vertical resize 6
    else
      execute "vertical resize" a:size
    endif
  endif
endfunction

"if focused close
"if not exists create
"if not visible show
"if not focused focus

function! s:ToggleOnTerminal(side, size) abort

  let curbuf = bufnr("%")

  " if terminal buffer have focus hide
  if getbufvar(curbuf, '&buftype') ==? 'terminal'
    silent execute bufwinnr(curbuf) . "hide"
    return
  endif

  let tpbl = []
  let tpbl = tabpagebuflist()

  " focus first visible terminal
  for buf in filter(range(1, bufnr('$')), 'bufexists(bufname(v:val)) && index(tpbl, v:val)>=0')
    if getbufvar(buf, '&buftype') ==? 'terminal'
      set switchbuf=useopen
      execute "sb" bufname(buf)
      return
    endif
  endfor

  " unhide first hidden terminal
  for buf in filter(range(1, bufnr('$')), 'bufexists(v:val) && index(tpbl, v:val)<0')
    if getbufvar(buf, '&buftype') ==? 'terminal'
      call PutTermPanel(buf, a:side, a:size)
      return
    endif
  endfor

  " create terminal
  call PutTermPanel(0, a:side, a:size)

endfunction


nnoremap <silent> <space>to :call <SID>ToggleOnTerminal('J', 6)<CR>
