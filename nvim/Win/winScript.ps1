function InstallWinFiles{

  New-Item -ItemType Directory -Path $env:LOCALAPPDATA"\nvim\"

  Copy-Item -Path .\*.vim -Destination $env:LOCALAPPDATA"\nvim\" -PassThru

  $folder =  "C:"+$env:HOMEPATH+"\.config\nvim\"

  New-Item -ItemType Directory -Path $folder -Force

  Copy-Item -Path ..\*.* -Destination $folder

}

function AdminCheck{

  $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())

  if($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){
    CreateSymLinks
  }
  else{
    Write-Host "Creation of Symlinks need admin priviliges" -B Red
    $resp = Read-Host "try to run in new window as administrator [y/n]"

    if($resp -eq "y"){
      Start-Process -Verb RunAs powershell -Args '-noexit', "Set-Location $PWD ; .\winScript.ps1"
    }

    # Start-Process -Verb RunAs powershell -Args '-noexit','-executionpolicy bypass -command', "\Set-Location "$PWD"\"; .\winScript.ps1\
  }

}

function CreateSymLinks{

  $userFolder = "c:\Users\czJaBeck"

  $lpath = $userFolder+'\AppData\Local\nvim'
  CreateSymLink $lpath"\init.vim" .\init.vim
  CreateSymLink $lpath"\ginit.vim" .\ginit.vim

  $lpath = $userFolder+'\.config\nvim'
  CreateSymLink $lpath"\init.vim" .\..\init.vim
  CreateSymLink $lpath"\coc.vim" .\..\coc.vim
  CreateSymLink $lpath"\deoplete.vim" .\..\deoplete.vim
  CreateSymLink $lpath"\coc-settings.json" .\..\coc-settings.json

}

function CreateSymLink{
  param(
    [string]$link
    ,[string]$target
  )
  New-Item -Path $link -ItemType SymbolicLink -Value $target -Force
}

# CreateSymLinks
# InstallWinFiles
AdminCheck
