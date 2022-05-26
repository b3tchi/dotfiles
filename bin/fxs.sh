#!/bin/bash

#parsing yaml function
parse_yaml() {
  local prefix=$2
  local s='[[:space:]]*' w='[a-zA-Z0-9_]*' fs=$(echo @|tr @ '\034')
  sed \
    -ne "s|,$s\]$s\$|]|" \
    -e ":1;s|^\($s\)\($w\)$s:$s\[$s\(.*\)$s,$s\(.*\)$s\]|\1\2: [\3]\n\1  - \4|;t1" \
    -e "s|^\($s\)\($w\)$s:$s\[$s\(.*\)$s\]|\1\2:\n\1  - \3|;p" $1 \
  | sed -ne "s|,$s}$s\$|}|" \
    -e ":1;s|^\($s\)-$s{$s\(.*\)$s,$s\($w\)$s:$s\(.*\)$s}|\1- {\2}\n\1  \3: \4|;t1" \
    -e "s|^\($s\)-$s{$s\(.*\)$s}|\1-\n\1  \2|;p" \
  | sed -ne "s|^\($s\):|\1|" \
    -e "s|^\($s\)-$s[\"']\(.*\)[\"']$s\$|\1$fs$fs\2|p" \
    -e "s|^\($s\)-$s\(.*\)$s\$|\1$fs$fs\2|p" \
    -e "s|^\($s\)\($w\)$s:$s[\"']\(.*\)[\"']$s\$|\1$fs\2$fs\3|p" \
    -e "s|^\($s\)\($w\)$s:$s\(.*\)$s\$|\1$fs\2$fs\3|p" \
  | awk -F$fs '{
    indent = length($1)/2;
    vname[indent] = $2;
    for (i in vname) { if (i > indent) { delete vname[i]; idx[i]=0 } }
    if(length($2)== 0){ name[indent]= ++idx[indent] };
    if (length($3) > 0) {
      vn="";
      for (i=0; i<indent; i++) { vn=(vn)(vname[i])("_")}
      printf("%s%s%s=\"%s\"\n", "'$prefix'",vn, vname[indent], $3);
    }
  }'
}

#check file exists
valid_yaml_secrets() {
  if [ ! -e "${sdir}/secrets/environ-secrets${suffix}.yml" ]; then
      echo local secrets file not found! ... will be now created.
      cp "$sdir"/secrets/environ-secrets-template.yml "$sdir"/secrets/environ-secrets${suffix}.yml
      chmod 400 "$sdir"/secrets/environ-secrets${suffix}.yml
      echo please adjust secrets placeholders in path
      echo "$sdir"/secrets/environ-secrets${suffix}.yml
      return 200
  fi

  secrets=$(parse_yaml "$sdir"/secrets/environ-secrets${suffix}.yml)

  pattern='^[a-z,A-Z,_,-]*=\"<SECRET_[A-Z,_]*>\"'
  if [[ $secrets =~ $pattern ]]; then
    echo local secrets file still contain default placeholders !
    echo please replace placeholder in path
    echo "$sdir"/secrets/environ-secrets${suffix}.yml
    return 200
  fi
}

#check file exists
valid_yaml_secrets2() {

  secretsPath=$1

  if [ ! -e "${secretsPath}/environ-secrets${suffix}.yml" ]; then
      echo local secrets file not found! ... will be now created.
      cp ${secretsPath}/environ-secrets-template.yml "$secretsPath"/environ-secrets${suffix}.yml
      chmod 400 "$secretsPath"/environ-secrets${suffix}.yml
      echo please adjust secrets placeholders in path
      echo "$secretsPath"/environ-secrets${suffix}.yml
      return 200
  fi

  secrets=$(parse_yaml "$secretsPath"/environ-secrets${suffix}.yml)

  pattern='^[a-z,A-Z,_,-]*=\"<SECRET_[A-Z,_]*>\"'
  if [[ $secrets =~ $pattern ]]; then
    echo local secrets file still contain default placeholders !
    echo please replace placeholder in path
    echo "$secretsPath"/environ-secrets${suffix}.yml
    return 200
  fi
}

#load named keys
load_named_args(){
  # echo $@
  if [ $# -gt 0 ]; then

    while [ $# -gt 0 ]; do

      if [[ $1 == *"--"* ]]; then

        param="${1/--/}"

        if [[ $2 == *"--"* || $# -eq 1 ]]; then
          declare -g $param=1
        else
          declare -g $param="$2"
        fi

      fi

      shift

    done
  fi
}

man_arg(){
  if [ $# -eq 1 ]; then
    return 100
  fi
  return $1
}
