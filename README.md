For installation use bash script
[dtlf sh](dtlf.sh)

```bash
#comment
echo something
echo "something \
      aggg"
echo something
```
spelling error
```sh
echo anything
echo anything
```

call powershell
```sh
#powershell.exe c:\\Users\\czJaBeck\\Dev\\Repositories\\AccessVCS\\tests\\test14.ps1
powershell.exe 'c:\Users\czJaBeck\Dev\Repositories\AccessVCS\tests\test14.ps1'
#cat '/mnt/c/Users/czJaBeck/Dev/Repositories/AccessVCS/tests/test14.ps1'
```

```bash
cd /mnt/c/ && cmd.exe /c echo %TEMP% && cd - | grep C: | sed 's/\xEF\xBB\xBF//g'

```

```powershell
Write-Host 'test2'
```

testing startifier
```bash
#%% ls ~/.local/share/nvim/session/ 
testx=$(find ~/.local/share/nvim/session/ -mindepth 1 -maxdepth 1 -printf '%f\n')
echo $testx
```

```vim
if index(['a','b'],'c') ==-1
  " echom expand('<cword>')
  let fname = tempname()
  let fname = substitute(fname,'/','','g') . '.ps1'
  let win_tmpps = trim(system('cd /mnt/c/ && cmd.exe /c echo %TEMP% && cd - | grep C: ')) . '\'

  let unx_tmpps = substitute(win_tmpps,'\\','/','g')
  let unx_tmpps = substitute(unx_tmpps,'C:','/mnt/c','g')
  ""let unx_tmpps = '/mnt/c/Users/czJaBeck/AppData/Local/Temp/' . fname
  let win_tmpps = win_tmpps . fname
  let unx_tmpps = unx_tmpps . fname
  echom win_tmpps
  echom unx_tmpps
  call writefile(['Write-Host hello'], unx_tmpps)

  let cmd = 'powershell.exe ''' . win_tmpps . ''''
  call VimuxRunCommand(cmd)

endif
```

```vim
  let tpbl = []
  let tpbl = tabpagebuflist()

  for buf in filter(range(1, bufnr('$')), 'bufexists(bufname(v:val)) && index(tpbl, v:val)>=0')
  ""  if getbufvar(buf, '&buftype') ==? 'terminal'
      echom getbufvar(buf, '&filetype')

      echom bufname(buf)
      if bufname(buf) == ".git/index"
      set switchbuf=useopen
      execute "sb" bufname(buf)
      ""echom getbufvar(buf, '&')
      ""return
   endif
  endfor
""echom expand('%')

```

```vim
let tpbl = []
let tpbl = tabpagebuflist()

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
endif
fu! StartsWith(longer, shorter) abort
  return a:longer[0:len(a:shorter)-1] ==# a:shorter
endfunction
if StartsWith(bufname(buf),"fugitive://" )
""set switchbuf=useopen
""execute "sb" bufname(buf)
echom "worktree"
""return
endif

endfor
""echom expand('%')

```
