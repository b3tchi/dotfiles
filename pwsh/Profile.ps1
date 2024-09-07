#adding clearing shortcut for powershel
Set-PSReadLineKeyHandler -Chord Ctrl+u -Function BackwardDeleteLine

Set-PSReadlineOption -EditMode vi
#
# $PSversion = $PSVersionTable.PSVersion.Major
#
# if ($PSversion -eq 7){
#     Set-PSReadLineKeyHandler -Chord Ctrl+u -Function BackwardDeleteInput
# } else {
#     Set-PSReadLineKeyHandler -Chord Ctrl+u -Function BackwardDeleteLine

Invoke-Expression (&starship init powershell)
