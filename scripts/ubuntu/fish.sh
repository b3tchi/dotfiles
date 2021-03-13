#fish shell
sudo apt-add-repository ppa:fish-shell/release-3
sudo apt update

sudo apt install -y
  \ fish
  \ curl

#change shell
chsh -s /usr/bin/fish
#get ohmyfish
curl -L https://get.oh-my.fish | fish
