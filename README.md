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
