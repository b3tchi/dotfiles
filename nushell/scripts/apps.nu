module apps {

  const apps_path = '~\Dev\Repositories\scripts\main\tools\apps'

  def myapps [] { 
    ls -s ( $apps_path | path expand ) | where type == dir | get name 
  }
  def actions [] { [install status ] }


  export def xlink [] {
    print 'xlink apps'

  }

  #install install if not exists
  #update only update if already installed
  #status if installed or any update if there is any action

  export def main [
      name:string@myapps
      action:string@actions
    ] {

      nu $"($apps_path)\\($name)\\install.nu" $action
      # print $resp

    return
  }

}
