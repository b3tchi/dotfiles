echom 'fugidiff'
fu! Testfu() abort
  echom 'spejbl'
endfunction

fu! StartsWith(longer, shorter) abort
  return a:longer[0:len(a:shorter)-1] ==# a:shorter
endfunction

fu! Checkdiff() abort
  let tpbl = []
  let tpbl = tabpagebuflist()

  let stagebuf = -1
  let wtbufid = -1
  let wttgtbufname = ""
  let wttgtbufid = -1
  let wttgtwinid = -1
  let wttgtbufwincount = 1

  for buf in filter(range(1, bufnr('$')), 'bufexists(bufname(v:val)) && index(tpbl, v:val)>=0')
    ""  if getbufvar(buf, '&buftype') ==? 'terminal'
    ""   echom getbufvar(buf, '&filetype')
    if bufname(buf) == "README.md"
      echom len(win_findbuf(buf))
    endif

    echom bufname(buf)
    if bufname(buf) == ".git/index"
      ""set switchbuf=useopen
      ""execute "sb" bufname(buf)
      echom "main"
      ""return
      let stagebuf = buf
    endif


    if StartsWith(bufname(buf),"fugitive://" )
      ""echom expand(bufname(buf):e)
      echom matchstrpos(bufname(buf),'\.git\/\/0\/')
      let posm = matchstrpos(bufname(buf),'\.git\/\/0\/')
      let wttgtbufname = bufname(buf)[posm[2]:]

      for difwin in filter(range(1, winnr('$')), 'getwinvar(v:val, "&diff") == 1')
        echom 'difwin'. difwin . ' - ' . bufname(winbufnr(difwin))
        if bufname(winbufnr(difwin)) == wttgtbufname
          let wttgtwinid = difwin
        endif

      endfor
      let wttgtbufid = bufnr(wttgtbufname)
      let wtbufid = buf
      let wttgtbufwincount = len(win_findbuf(wttgtbufid))
      ""set switchbuf=useopen
      ""echom getbufvar(buf, '&')

      ""execute "sb" bufname(buf)
      echom "worktree"


      ""return
    endif

  endfor


  let r = {}

  let r.wt = {}
  let r.wt.bufid = wtbufid
  let r.wt.fname = wttgtbufname

  let r.wt.tgtbufid = wttgtbufid
  let r.wt.tgtwinid = wttgtwinid
  let r.wt.tgtwincount = wttgtbufwincount

  let r.stage = {}
  let r.stage.bufid = stagebuf

  return r

endfunction

fu! DiffTog() abort

  let r = Checkdiff()
  ""echom expand('%')
  set switchbuf=useopen
  execute "sb" bufname(r.stage.bufid)

  let curfname = getline('.')[2:] "command line content current cursor
  let cursection = getline(line("'{")+1) "line content on the beginning of paragraph

  echom curfname
  echom cursection

  "cleanup
  if r.wt.bufid != -1

    "new item
    if r.wt.tgtwincount == 1
      execute "bd" r.wt.tgtbufid
    else
      if r.wt.tgtwinid != -1 "close window
        echom 'close window ' . r.wt.tgtwinid
        execute r.wt.tgtwinid . "wincmd q"
      endif
    endif

    execute "bd" r.wt.bufid

  endif

  " return

  " echom expand("<cfile>")
  if (curfname != r.wt.fname) || (curfname == r.wt.fname && r.wt.tgtwinid == -1)
    echom 'ndiff'
    normal o
    normal zR
    normal gg
    execute "Gdiffsplit"
    normal ]c
    ""set switchbuf=useopen
    ""execute "sb" bufname(stagebuf)
    ""normal dd
    set switchbuf=useopen
    execute "sb" bufname(r.stage.bufid)
  else
    echom 'none'
  endif

endfunction

fu! NextItem() abort

  let r = Checkdiff()
  ""echom expand('%')
  " set switchbuf=useopen
  " execute "sb" bufname(r.stage.bufid)
  "
  " let curfname = getline('.')[2:] "command line content current cursor
  " let cursection = getline(line("'{")+1) "line content on the beginning of paragraph
  "
  " echom curfname
  " echom cursection

  "new item
  if r.wt.tgtwinid != -1 "close window
    let currwin = winnr()
    execute r.wt.tgtwinid . 'wincmd w'
    normal ]c
    execute currwin . 'wincmd w'
  endif

endfunction
