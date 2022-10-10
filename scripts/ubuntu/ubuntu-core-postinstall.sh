log=$0.log

if [ ! -f $log ]; then
  echo "init" >> $log
fi

#fish shell
step='fish'
if ! grep -q $step $log; then

  #add repository
  sudo apt-add-repository ppa:fish-shell/release-3
  sudo apt update

  sudo apt install fish

  #change shell
  chsh -s /usr/bin/fish

  #get ohmyfish
  sudo apt install curl
  curl -L https://get.oh-my.fish | fish

  echo $step >> $log
fi

#zsh TBD
step='zsh'
if ! grep -q $step $log; then

  #add repository
  sudo apt update

  sudo apt install zsh

  #change shell
  chsh -s /usr/bin/zsh

  echo $step >> $log
fi


#nodejs
step='node'
if ! grep -q $step $log; then

  sudo apt remove --purge nodejs npm

  sudo apt clean

  sudo apt autoclean

  sudo apt install -f

  sudo apt autoremove

  sudo apt install curl

  # cd ~

  curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash -

  sudo apt-get install -y nodejs

  curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -

  sudo apt-get update && sudo apt-get install yarn

  echo $step >> $log
fi

#nodejs-nvm

step='node-nvm'
if ! grep -q $step $log; then

  sudo apt remove --purge nodejs npm

  sudo apt clean

  sudo apt autoclean

  sudo apt install -f

  sudo apt autoremove

  sudo apt install curl

  # cd ~

  curl -sL https://deb.nodesource.com/setup_14.x | sudo -E bash -

  sudo apt-get install -y nodejs

  curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -

  sudo apt-get update && sudo apt-get install yarn

  echo $step >> $log
fi

#python
step='python'
if ! grep -q $step $log; then

  sudo apt update

  sudo apt install -y \
    python3 \
    python3-pip \

  echo $step >> $log
fi

#pyenv
step='pyenv'
if ! grep -q $step $log; then

  sudo apt install -y \
    make \
    donebuild-essential \
    libssl-dev zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    wget \
    curl \
    llvm \
    libncurses5-dev \
    libncursesw5-dev xz-utils \
    tk-dev \
    libffi-dev \
    liblzma-dev \
    python-openssludo \

  echo $step >> $log
fi

#bat
step='bat'
if ! grep -q $step $log; then

  # If we use 0.18.0:
  VERSION='0.18.0'
  sudo apt-get install wget

  wget https://github.com/sharkdp/bat/releases/download/v${VERSION}/bat_${VERSION}_amd64.deb
  sudo dpkg -i bat_${VERSION}_amd64.deb

  echo $step >> $log
fi

#neovim
step='neovim'
if ! grep -q $step $log; then

  sudo apt install -y \
    neovim \
    fzf \
    ripgrep \

  sudo npm install neovim -g
  pip3 install pynvim

  echo $step >> $log
fi


#lazygit
step='lazygit'
if ! grep -q $step $log; then

  sudo add-apt-repository ppa:lazygit-team/daily
  sudo apt-get update
  sudo apt-get install lazygit

  echo $step >> $log
fi



