#!/bin/bash

#check array if contains all mandatory items
arguments_from_env(){

  if [[ ! -z $SCRIPTS_NS_PREFIX ]]; then

    local global_prefix=$SCRIPTS_NS_PREFIX"_"

    for key in "$@"; do

      # echo $j ${args[$j]}
      #check arguments
      local varname=${key}
      local varval=${!varname} #indirect parameter expansion (bash specific)
      # echo "argsx $varname $varval"

      if [[ -z ${varval} ]]; then

        #try to take from env vars
        local gvarname=${global_prefix}${varname^^}
        local gvarval=${!gvarname} #indirect parameter expansion (bash specific)

        # echo "vartogvar $varname $gvarname $gvarval"
        if [[ ! -z ${gvarval} ]]; then
          declare -g $varname=${gvarval}
          # echo "$varname"
        fi
      fi

  done

fi

}

#check array if contains all mandatory items
missing_args_check(){

  local -a to_check=("$@")

  for (( j=0; j<${#to_check[@]}; j+=1 )); do

    #check arguments
    varname=${to_check[$j]}
    varval=${!varname} #indirect parameter expansion (bash specific)

    if [[ -z ${varval} ]]; then
      echo "${varname}"
    fi

  done

}

exit_help(){
local arguments='
  # mandatory arguments
  $!mandatory_args[@] $mandatory_args[$!mandatory_args[@]]

  # optional arguments
  $!optional_args[@] $optional_args[$!optional_args[@]]
  '

  print_message "$1$arguments"
  exit 0
}

exit_if_missing_arguments(){
  missing_args=($(missing_args_check "$@"))

  local message_missing='
    # missinng mandatory arguments
    cant continue ... please enter argumest(s) bellow

    $!missing_args[@] $mandatory_args[$!missing_args[@]]
    '

  if [[ ! -z $missing_args ]]; then
    print_message "$message_missing"
    exit 1
  fi

}

print_message(){
  # IFS=$'\n' read -t -r -a lists <<< "$text"
  # readarray -t lists <<<"$text"
  mapfile -t lists <<<$1

  # declare -p lists

  ITEMHI='\033[0;32m'
  HEADER='\033[1;33m'
  NC='\033[0m' # No Color

  i=0
  lc=$((${#lists[@]} -1))
  dedentby=${#lists[$lc]} #take indentation level from last item

  for item in "${lists[@]}"; do

    if (( $i > 0 && $lc > $i )); then

      item="${item:${dedentby}}"
      # echo $i
      if [[ "$item" =~ "\$!" ]]; then

        varname_key=$(echo $item | grep -Po '\$!\K[a-z_]+' | head -n 1)
        varname_val=$(echo $item | grep -Po '\$\K[a-z_]+' | head -n 1)

        declare -n keys=$varname_key
        declare -n items=$varname_val

        unset ks
        if [[ $(declare -p "$varname_key") =~ "-A" ]]; then
          declare -a ks=("${!keys[@]}")
        else
          declare -a ks=("${keys[@]}")
        fi

        lns=''

        for (( j=0; j<${#ks[@]}; j+=1 )); do
          tkey=${ks[$j]}
          val=${items[$tkey]}

          tkey=${ITEMHI}"--${tkey//_/-}"${NC}

          patternkey="\$!${varname_key}[@\]"
          patternval="\$${varname_val}\[${patternkey}\]"

          ln="$item"
          ln="${ln//${patternval}/${val}}"
          ln="${ln//${patternkey}/${tkey}}"

          echo -e "$ln"

        done

      else

        if [[ "$item" =~ "# " ]]; then
          echo -e ${HEADER}"${item}"${NC}
        else
          echo -e "$item"
        fi
      fi
    fi

    i=$((i + 1))

  done

}

route(){

  local file
  local dirpath

  #handle if its link
  if [[ -L "$0" ]]; then
    dirpath=$(readlink -f "$0")
    dirpath=$(dirname "$dirpath")/
  else
    dirpath=$(dirname "$0")/

    if [[ "$1" == "$(basename $dirpath)" ]]; then
      shift
      echo "first argument can't be name of main.sh folder '$(basename $dirpath)'"
      echo "have to be skipped when 'main.sh' is called directly"
      echo "call should like that:"
      echo "$0 $@"
      exit 0
    fi

  fi

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

        #convert named argument to bash variable style --abc-xyz => abc_xyz
        param="${1/--/}"
        param="${param//-/_}"

        shift

        #if last argument is flag $# eq 0 or next is another named argement
        if [[ $# -eq 0 || $1 == "--"* ]]; then
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

  #load script file and main variables
  source $dirpath$file

  #print help and return description
  [[ ! -z $help ]] && exit_help "$description"

  #passing only keys to load
  arguments_from_env "${!mandatory_args[@]}" "${!optional_args[@]}"

  #exit if there are not all arguments
  exit_if_missing_arguments "${!mandatory_args[@]}"

  #call main process
  main

}

route "$@"

#TODO shift argemnts form other then first position
#https://stackoverflow.com/questions/4827690/how-to-change-a-command-line-argument-in-bash
# set -- "${@:1:2}" "new" "${@:4}"
