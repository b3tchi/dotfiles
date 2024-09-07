#Cleanup registry shell path 

`HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders`

```ps1
New-ItemProperty 
  'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' 
  Personal -Value 'Your New Path Here' -Type ExpandString -Force
```

# profiles paths

```ps1
$profile | select *
```
