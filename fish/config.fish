# Load pyenv automatically by adding
# the following to ~/.config/fish/config.fish:

set -x PATH "$HOME/.local/bin" $PATH #dotbot path 
set -x PATH "$HOME/.pyenv/bin" $PATH #pyenv for python additons for nvim

status --is-interactive; and pyenv init - | source
status --is-interactive; and pyenv virtualenv-init - | source

# set -x PATH "$HOME/.pyenv/bin" $PATH #fishhi
# . (pyenv init - fish)
# eval "$(pyenv init -)"
# eval "$(pyenv virtualenv-init -)"
