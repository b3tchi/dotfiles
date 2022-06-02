#!/bin/bash

route(){


  local file
  local dirpath

  #handle if its link
  if [[ -L "$0" ]]; then
    dirpath=$(readlink -f "$0")
  fi

  dirpath=$(dirname "$dirpath")/

  if [ $# -gt 0 ]; then

    while [ $# -gt 0 ]; do

      if [ -d $dirpath$1 ]; then

        dirpath=$dirpath${1}/
        shift

      elif [ -f $dirpath$1 ]; then

        file=$1
        shift

      elif [[ $1 == *"--"* ]]; then

        param="${1/--/}"
        shift

        if [[ $1 == *"--"* || $# -eq 1 ]]; then
          declare -g $param=1
        else
          declare -g $param="$1"
          shift
        fi

      else

        break

      fi

    done
  fi

  # echo $dirpath$file
  source $dirpath$file

}

route "$@"

# tagPush(){
#   local tag=$1
#   local user=$2
#   local mail=$3
#
#   if [ -z $(git tag -l --points-at HEAD) ]; then
#
#     git config --global user.email "$mail"
#     git config --global user.name "$user"
#
#     # not need current tag
#     # git tag -a $newversion -m "test tag commit"
#     git tag $tag
#     git push origin $tag
#
#     echo "tagging: $tag"
#   else
#     echo 'already tagged'
#   fi
# }
#
# incrementVersion() {
#   local delimiter=.
#   local array=($(echo "$1" | tr $delimiter '\n'))
#   array[$2]=$((array[$2]+1))
#   if [ $2 -lt 2 ]; then array[2]=0; fi
#   if [ $2 -lt 1 ]; then array[1]=0; fi
#   echo $(local IFS=$delimiter ; echo "${array[*]}")
# }
#
# getNextVersion(){
#   local lchangeSize=$1
#
#   git fetch --all --tags &> /dev/null
#   git tag -l --sort -v:refname &>/dev/null
#
#   local lastversion=$(git tag -l --sort=-v:refname | grep -v 202 | head -n1)
#   # local newversion=$(incrementVersion "$lastversion" $lchangeSize)
#
#   echo $lastversion
#
# }
