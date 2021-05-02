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

#nodejs
step='node'
if ! grep -q $step $log; then

  sudo apt update

  sudo apt install -y \
    nodejs \
    npm \

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

#neovim
step='neovim'
if ! grep -q $step $log; then

  sudo apt install neovim
  sudo apt install fzf
  sudo apt install ripgrep
  sudo npm install neovim
  pip3 install pynvim

  echo $step >> $log
fi
