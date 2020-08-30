New-Item -ItemType Directory -Path $env:LOCALAPPDATA"\nvim\"

Copy-Item -Path .\*.vim -Destination $env:LOCALAPPDATA"\nvim\" -PassThru

$folder =  "C:"+$env:HOMEPATH+"\.config\nvim\"

New-Item -ItemType Directory -Path $folder -Force

Copy-Item -Path ..\*.* -Destination $folder

