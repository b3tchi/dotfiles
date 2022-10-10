  Plug 'christoomey/vim-tmux-navigator'
  Plug 'preservim/vimux'

function LoadedVimux()
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

    let b:mdcode = mdblock.code
    let b:mdlang = mdblock.lang
    "bash command
    if index(['bash','sh'],mdblock.lang) > -1
      " let lines = join(mdblock.code, "\n") . "\n"
      " call VimuxRunCommand(lines)

lua << EOF

if type(mdblock_bash)=='function' then
  mdblock_bash(vim.b.mdcode)
else
  print('not exists')
end

EOF
      "powershell
    elseif index(['ps','powershell'],mdblock.lang) > -1
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


    elseif index(['cs','csharp'],mdblock.lang) > -1

lua << EOF

if type(mdblock_csharp)=='function' then
  mdblock_csharp(vim.b.mdcode)
else
  print('not exists')
end

EOF

elseif index(['pwsh'],mdblock.lang) > -1

lua << EOF

if type(mdblock_pwsh)=='function' then
  mdblock_pwsh(vim.b.mdcode)
else
  print('not exists')
end

EOF

      "vimscript
    elseif index(['vim','viml'],mdblock.lang) > -1
      let lines = mdblock.code
      let tmp = tempname()
      call writefile(lines, tmp)
      exec 'source '.tmp
      call delete(tmp)
    endif
  endfunction

  function! FolderTemp()
    let temppath = '/tmp/nvim_mdblocks/'
    " !mkdir -p '/tmp/nvim_mdblocks/'
    call mkdir(temppath,'p')
    return temppath
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
  nnoremap <silent> <space>cc :VimuxRunCommand getline(".")<CR>
  nnoremap <silent> <space>cr vip "vy :call VimuxSlime()<CR>
  nnoremap <silent> <space>cb :call VimuxMdBlock()<CR>

  " nnoremap <space>cz :lua require'telegraph'.telegraph({how='tmux_popup', cmd='man '})<Left><Left><Left>

  vmap <space>cr "vy :call VimuxSlime()<CR>
endfunction

augroup LoadedVimux
  autocmd!
  autocmd User PlugLoaded call LoadedVimux()
augroup END
