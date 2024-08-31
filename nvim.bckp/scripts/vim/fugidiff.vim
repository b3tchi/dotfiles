" echom 'fugidiff'
fu! Testfu() abort
  echom 'spejbl'
endfunction

fu! StartsWith(longer, shorter) abort
  return a:longer[0:len(a:shorter)-1] ==# a:shorter
endfunction

fu! EndsWith(longer, shorter) abort
  return a:longer[(len(a:longer)-len(a:shorter)):] ==# a:shorter
endfunction

lua << EOF

function _G.test()
  local buffers = {}
  local len = 0
  -- local options_listed = options.listed
  local vim_fn = vim.fn
  local buflisted = vim_fn.buflisted

  -- current table id
  local tabid = vim.fn.tabpagebuflist()
  -- print(tabid)

  -- function string.starts(String,Start)
  --    return string.sub(String,1,string.len(Start))==Start
  -- end


  -- list all buffers in current tab
  for buffer = 1, vim_fn.bufnr('$') do
    if vim.fn.index(tabid, buffer) ~= -1 then
      -- len = len + 1
      -- print(vim.fn.bufname(buffer))
      -- print(vim.fn.index(tabid, buffer))
      -- buffers[len] = buffer


      bufname = tostring(vim.fn.bufname(buffer))
      print(str)

      endwidth="nvim/scripts$"

      if (bufname:find(endwidth ) ~= nil) then
        stagebufid = buffer

      -- string.starts(vim.fn.bufname(buffer),'nvim/scripts')
      end

    end
  end
end
EOF

" call v:lua.test()

fu! Checkdiff() abort
  let tpbl = []
  let tpbl = tabpagebuflist()

  let stagebuf = -1
  let wtbufid = -1
  let wttgtbufname = ""
  let wttgtbufid = -1
  let wttgtwinid = -1
  let wttgtbufwincount = 1

  "loop all tables in current buffer
  for buf in filter(range(1, bufnr('$')), 'bufexists(bufname(v:val)) && index(tpbl, v:val)>=0')

    " main fugitive buffer
    if getbufvar(buf, '&filetype') == "fugitive"
      " echom "main"
      let stagebuf = buf

    " other fugitive buffers
    else

      let bfname = bufname(buf)
      "check fugitive buffers
      if StartsWith(bfname,"fugitive://" )

        " extract buffer name from fugitive diff buffer
        let posm = matchstrpos(bfname,'\.git\/\/0\/')
        let wttgtbufname = bfname[posm[2]:]
        " echom posm

        "find window winthin current buffer
        for difwin in filter(range(1, winnr('$')), 'getwinvar(v:val, "&diff") == 1')
          let difname = bufname(winbufnr(difwin))
          " echom 'difwin'. difwin . ' - ' . difname

          "identify openned diff windows from fugitive Gdiffsplit
          if EndsWith(difname, wttgtbufname) && !StartsWith(difname,"fugitive://" )
            let wttgtwinid = difwin
          endif

        endfor

        let wttgtbufid = bufnr(wttgtbufname)
        let wtbufid = buf
        let wttgtbufwincount = len(win_findbuf(wttgtbufid))
        " echom "worktree"
      endif
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

fu! DiffTog(toggleDisabled) abort

  let r = Checkdiff()

  " echo r
  if bufnr("%") != r.stage.bufid
    set switchbuf=useopen
    execute "sb" bufname(r.stage.bufid)
  endif

  let curfname = getline('.')[2:] "command line content current cursor
  let cursection = getline(line("'{")+1)[:7] "line content on the beginning of paragraph

  "repeating
  if (a:toggleDisabled == 1) && (curfname == r.wt.fname )
    return
  endif

  " echom curfname
  " echom cursection

  "cleanup
  if r.wt.bufid != -1
    "new item
    if r.wt.tgtwincount == 1
      execute "bd" r.wt.tgtbufid
    else
      if r.wt.tgtwinid != -1 "close window
        " echom 'close window ' . r.wt.tgtwinid
        execute r.wt.tgtwinid . "wincmd q"
      endif
    endif

    execute "bd" r.wt.bufid

  endif

  "exit while not in Unstaged
  if cursection != 'Unstaged'
    return
  endif
  "exit when toggling is off and no fugitive buffer
  if (a:toggleDisabled == 1) && (r.wt.bufid == -1)
    return
  endif

  if (curfname != r.wt.fname) || (curfname == r.wt.fname && r.wt.tgtwinid == -1)

    "open in new window
    normal o
    "start split
    execute "Gdiffsplit!"

    "go on top
    normal gg
    "go on first hunk
    execute "GitGutterNextHunk"
    " execute "Gitsigns next_hunk"

    "switch back to fugitive
    set switchbuf=useopen
    execute "sb" bufname(r.stage.bufid)
  endif

endfunction

fu! PrevChange() abort

  let r = Checkdiff()

  if r.wt.tgtwinid != -1 "close window
    echo win_execute(win_getid(r.wt.tgtwinid ),'GitGutterPrevHunk')
    " echo win_execute(win_getid(r.wt.tgtwinid ),'Gitsigns prev_hunk')
  endif

endfunction

fu! NextChange() abort

  let r = Checkdiff()

  if r.wt.tgtwinid != -1 "close window
    echo win_execute(win_getid(r.wt.tgtwinid ),'GitGutterNextHunk')
    " echo win_execute(win_getid(r.wt.tgtwinid ),'Gitsigns next_hunk')
  endif

endfunction
