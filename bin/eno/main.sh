#!/bin/bash

route(){


  local file
  local dirpath

  #handle if its link
  if [[ -L "$0" ]]; then
    dirpath=$(readlink -f "$0")
    dirpath=$(dirname "$dirpath")/
  else
    dirpath=$(dirname "$0")/
  fi

  # echo "$0"
  # echo "$dirpath"

  #preload
  if [ -f "${dirpath}auto.sh" ]; then
    . "${dirpath}auto.sh"
  fi

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

        # if [[ $1 == *"--"* || $# -eq 1 ]]; then
        if [[ $1 == *"--"* ]]; then
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

