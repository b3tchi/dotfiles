#!/bin/bash

# Fix TMPDIR for Termux
mkdir -p ~/tmp
export TMPDIR=~/tmp

# Add to .bashrc if not already there
if ! grep -q 'export TMPDIR=~/tmp' ~/.bashrc 2>/dev/null; then
    echo 'export TMPDIR=~/tmp' >> ~/.bashrc
    echo "Added TMPDIR to .bashrc"
fi

# Rename .dotfiles to .dotfiles if needed
if [ -d ~/.dotfiles ]; then
    mv ~/.dotfiles ~/.dotfiles
    echo "Renamed .dotfiles -> .dotfiles"
fi

# Fix references in config files
if command -v grep &>/dev/null; then
    files=$(grep -rl "\.dotfiles" ~/ 2>/dev/null)
    if [ -n "$files" ]; then
        echo "Fixing references in:"
        echo "$files"
        echo "$files" | xargs sed -i 's/\.dotfiles/\.dotfiles/g'
        echo "Done fixing references."
    else
        echo "No references to .dotfiles found."
    fi
fi

echo "All done!"
