# For nushell version >= 0.87.0
def --env --wrapped lfcd [...args:string] { 
  cd (lf -print-last-dir ...$args)
}