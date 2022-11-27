#!/bin/bash

function ml(){
  mkdir -p $3

  if [ ! -z "$4" ]; then
      # echo "argument supplied"
      filename=$4
  else

    if echo $2 | grep -q "/"; then
      # echo "slash"
      filename=${2##*/}
    else
      # echo "no slash"
      filename=$2
    fi
  fi

  target=$3$filename
  source=$1$2

  #file in path
  if [[ (-f $target || -d $target ) && ! -L $target ]]; then
    echo "WW - not yet link placed ... $source"
    rm -rf $target
  fi

  #linked before
  if [[ -L $target ]]; then
    # echo 'target is link'
    currlink=$(readlink $target)
    if [[ $currlink == $source ]]; then
        echo "II - already linked ... $source"
        return 0
      else
        echo "WW - link not match removed ... $source"
        rm -rf $target
      fi
  fi

  #create link
  ln -sf $source $target
  echo "OK - linked ... $2 to $target"

}

d=~/dotfiles/

# ml $d nvim/init.vim ~/lnk/
#bash
ml $d profile ~/ .profile
ml $d bashrc ~/ .bashrc
ml $d bash_logout ~/ .bash_logout
#git
ml $d gitconfig ~/ .gitconfig
# ml $d ssh/config ~/.ssh/ # not govern through moved to private repo
ml $d tmux/tmux.conf ~/ .tmux.conf
ml $d tigrc ~/ .tigrc
ml $d visidata/visidatarc ~/ .visidatarc

#bat
ml $d bat ~/.config/
ml $d fzf/themes/tokyonight.conf ~/.shell_config/shared/ fzf-theme

#zsh
ml $d profile ~/ .zprofile
ml $d zsh/zshrc ~/ .zshrc
ml $d zsh/p10k.zsh ~/ .p10k.zsh

#fish
ml $d fish/config.fish ~/.config/fish/
ml $d fish/fish_user_key_bindings.fish ~/.config/fish/functions/
ml $d fish/n.fish ~/.config/fish/functions/
ml $d fish/n1.fish ~/.config/fish/functions/

#nvim
ml $d nvim/init.vim ~/.config/nvim/
# ml $d nvim/plugins/vim/coc-settings.json ~/.config/nvim/ #not used

##GUI starts here

#nvim-#Qt
ml $d nvim/Win/ginit.vim ~/.config/nvim/

#code
ml $d code/settings.json ~/.config/Code/User/
ml $d code/keybindings.json ~/.config/Code/User/

#wezterm
ml $d wezterm/wezterm.lua ~/.config/wezterm/

#firefox not working yet
md $d firefox/personal ~/.mozilla/firefox/

#kde
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

