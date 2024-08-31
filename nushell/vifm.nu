# For nushell version >= 0.87.0
def --env --wrapped vm [...args:string] { 
  cd (vifm --choose-dir - ...$args)
}
