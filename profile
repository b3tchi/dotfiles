# ~/.profile: executed by the command interpreter for login shells. This file
# is not read by bash(1), if ~/.bash_profile or ~/.bash_login exists. see
# /usr/share/doc/bash/examples/startup-files for examples. the files are
# located in the bash-doc package.

# the default umask is set in /etc/profile; for setting the umask for ssh
# logins, install and configure the libpam-umask package.
#umask 022

# if running bash
if [ -n "$BASH_VERSION" ]; then
  # include .bashrc if it exists
  if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
  fi
fi

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/bin" ] ; then
  export PATH="$HOME/bin:$PATH"
fi

# set PATH so it includes user's private bin if it exists
if [ -d "$HOME/.local/bin" ] ; then
  export PATH="$HOME/.local/bin:$PATH"
fi

# if rust is installed then added runtime to path
if [ -f "$HOME/.cargo/env" ] ; then
  . "$HOME/.cargo/env"
fi

# if dotnet is install then add binaries tools path
if [ -d "$HOME/.dotnet/tools" ] ; then
  export PATH="$HOME/.dotnet/tools:$PATH"
fi

# if go is present
if [ -d "/usr/local/go" ] ; then
  export GOPATH="$HOME/go"
  export PATH="$PATH:/usr/local/go/bin:$HOME/bin:$GOPATH/bin"
fi

# sqlcmd items
if [ -d "/opt/mssql-tools/bin" ] ; then
  export PATH="$PATH:/opt/mssql-tools/bin"
fi

#check if not on ssh tunel session
if [ -n "$SSH_CLIENT" ] || [ -n "$SSH_TTY" ]; then
  SESSION_TYPE=remote/ssh
# many other tests omitted
else
  case $(ps -o comm= -p $PPID) in
    sshd|*/sshd) SESSION_TYPE=remote/ssh;;
  esac
fi

#check if wsl then start docker
if [ -n $IS_WSL ]; then
  if service docker status 2>&1 | grep -q "is not running"; then
    wsl.exe -d "${WSL_DISTRO_NAME}" -u root -e /usr/sbin/service docker start >/dev/null 2>&1
  fi
fi
