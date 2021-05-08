function ml(){
  mkdir -p $3

  if [ ! -z "$4" ]; then
      echo "argument supplied"
      filename=$4
  else

    if echo $2 | grep -q "/"; then
      echo "slash"
      filename=${2##*/}
    else
      echo "no slash"
      filename=$2
    fi
  fi


  # filename=$3${2##*/}

  target=$3$filename

  rm -rf $target
  ln -sf $1$2 $target
  echo "linked $2 to $target"
}

d=~/dotfiles/

# ml $d nvim/init.vim ~/lnk/
#bash
ml $d profile ~/ .profile
ml $d bashrc ~/ .bashrc
ml $d bash_logout ~/ .bash_logout
ml $d gitconfig ~/ .gitconfig
ml $d ssh/config ~/.ssh/
ml $d tmux.conf ~/ .tmux.conf
ml $d bat.conf ~/.config/bat/ config
ml $d zshrc ~/ .zshrc

# zsh nnn tbd

#fish
ml $d fish/config.fish ~/.config/fish/
ml $d fish/fish_user_key_bindings.fish ~/.config/fish/functions/
ml $d fish/n.fish ~/.config/fish/functions/
ml $d fish/n1.fish ~/.config/fish/functions/

#NVIM
ml $d nvim/init.vim ~/.config/nvim/
ml $d nvim/coc-settings.json ~/.config/nvim/
ml $d nvim/coc.vim ~/.config/nvim/
ml $d nvim/incubator.vim ~/.config/nvim/
    # ~/.config/nvim/deoplete.vim:
#NVIM-#QT
ml $d nvim/Win/ginit.vim ~/.config/nvim/

#VsCode
ml $d code/settings.json ~/.config/Code/User/
ml $d code/keybindings.json ~/.config/Code/User/

#KDE
ml $d kde/konsoleui.rc ~/.local/share/kxmlgui5/konsole/
ml $d kde/konsoleui.rc ~/.config/
ml $d kde/sessionui.rc ~/.local/share/kxmlgui5/konsole/
ml $d kde/kdeglobals ~/.config/
ml $d kde/kglobalshortcutsrc ~/.config/
ml $d kde/khotkeysrc ~/.config/
ml $d kde/kwinrc ~/.config/
ml $d kde/myFirstServiceMenu.desktop ~/.local/share/kservices5/ServiceMenus/
ml $d kde/konsolerc ~/.config/
ml $d kde/kwinrulesrc ~/.config/
ml $d kde/krunnerrc ~/.config/

  #Latte
    # ~/.config/latte/Default.layout.latte:
      # ml $d kde/latte/Default.layout.latte

# cd -
