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
ml $d profile ~/ .zprofile
ml $d bashrc ~/ .bashrc
ml $d bash_logout ~/ .bash_logout
ml $d gitconfig ~/ .gitconfig
ml $d ssh/config ~/.ssh/
ml $d tmux.conf ~/ .tmux.conf
ml $d bat.conf ~/.config/bat/ config

#zsh
ml $d zsh/zshrc ~/ .zshrc
ml $d zsh/p10k.zsh ~/ .p10k.zsh

#scripts
ml $d bin/tat ~/.local/bin/
ml $d bin/ff ~/.local/bin/
ml $d bin/nvim-sessionizer ~/.local/bin/
ml $d bin/nvim-startifier ~/.local/bin/
ml $d bin/gwt/main.sh ~/.local/bin/ gwt
ml $d bin/ak/main.sh ~/.local/bin/ ak
ml $d bin/azdops/pipeline.sh ~/.local/bin/ azdpipes
ml $d bin/azdops/variables.sh ~/.local/bin/ azdvars
ml $d bin/fxs.sh ~/.local/bin/ fxs
# ml $d bin/gwt/gwt ~/.local/bin/

#bin
chmod +x ${d}bin/*
chmod +x ${d}bin/gwt/main.sh
chmod +x ${d}bin/ak/main.sh
chmod +x ${d}bin/azdops/*.sh

#fish
ml $d fish/config.fish ~/.config/fish/
ml $d fish/fish_user_key_bindings.fish ~/.config/fish/functions/
ml $d fish/n.fish ~/.config/fish/functions/
ml $d fish/n1.fish ~/.config/fish/functions/

#nvim
ml $d nvim/init.vim ~/.config/nvim/
ml $d nvim/coc-settings.json ~/.config/nvim/
ml $d nvim/coc.vim ~/.config/nvim/
ml $d nvim/incubator.vim ~/.config/nvim/
ml $d nvim/lualsp.vim ~/.config/nvim/
ml $d nvim/fugidiff.vim ~/.config/nvim/
ml $d nvim/vimspector.json ~/.config/nvim/

ml $d nvim/plugins/gruvbox.vim ~/.config/nvim/plugins/
ml $d nvim/plugins/solarized.vim ~/.config/nvim/plugins/
    # ~/.config/nvim/deoplete.vim:
#nvim-#Qt
ml $d nvim/Win/ginit.vim ~/.config/nvim/

#nvim sessions
ml $d nvim/session/dotfiles ~/.local/share/nvim/session/
ml $d nvim/session/wiki ~/.local/share/nvim/session/
ml $d nvim/session/scripts ~/.local/share/nvim/session/

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

  #latte
    # ~/.config/latte/Default.layout.latte:
      # ml $d kde/latte/Default.layout.latte

# cd -
