#!/bin/bash

#script root dir
sdir=$(dirname "$0")

if [ $(basename "$0") = "azdops" ]; then
  echo system
fi

exit

#calculated variables
root=${sdir}/../../..

#load support fxs
source ${root}/ci/scripts/fxs.sh

# scripts variables
source ${sdir}/vars

# name parameters
load_named_args "$@"

echo ${root}/ci/scripts/fxs.sh

#select which id to use if not use empty
[ -z $envid ] && envid='0'

mvar() {
  varname=$1
  echo ${!varname}
}

#pick variable by id
pipelineName=$(mvar "pipeline${envid}Name")
pipelineDescription=$(mvar "pipeline${envid}Description")
pipelinePath=${root}/$(mvar "pipeline${envid}Path")

#calculate some of the variables
commitText=${commitText:-"$defaultCommitText"} #substitute commit text if empty
branchName=$(git rev-parse --abbrev-ref HEAD)
repositoryUrl="$repositoryUrlRoot"$(git config --get remote.origin.url | sed -e 's/.*://' | sed -e 's/.git$//')
organizationUrl="$azureUrlRoot$organizationName"

#commit all changes in ci folder
[ -d "${root}/ci/pipelines" ] && git add "${root}/ci/pipelines"
[ -d "${root}/ci/variables" ] && git add "${root}/ci/variables"
[ -d "${root}/ci/scripts" ] && git add "${root}/ci/scripts"
[ -d "${root}/ci/iac" ] && git add "${root}/ci/iac"

[ -z $create ] && echo "created empty"

#commit changes
git commit -m "$commitText"
git push origin "$branchName"

#list end point
# az devops service-endpoint list -o table

#to connect to the project
az devops configure --defaults organization="$organizationUrl" project="$projectName"

pipelineId=$(az pipelines show \
  --name "$pipelineName" \
  --query "id")

#check if created
re='^[0-9]+$'
if ! [[ $pipelineId =~ $re ]] ; then

  if [[ ! -z $silent && -z $create ]] ; then
    echo "pipeline not found and --create argument not found ... exitting"
    exit
  fi

  if [ -z $silent && -z $create ]; then
    prompt="pipeline not found and --create argument not found do you want to create pipeline?"
    read -p "$prompt" create
  fi

  echo "pipeline not found will be created"

  if [ ! -z $create ]; then

    echo $pipelineName
    echo $pipelineDescription
    echo $pipelinePath
    echo $repositoryUrl
    echo $branchName

    az pipelines create \
      --name "$pipelineName" \
      --description "$pipelineDescription" \
      --yml-path "$pipelinePath" \
      --repository "$repositoryUrl" \
      --branch "$branchName" \

    pipelineId=$(az pipelines show \
      --name "$pipelineName" \
      --query "id")

    if ! [[ $pipelineId =~ $re ]] ; then
      echo "creation failed no id"
      exit 0
    fi

  fi

fi


  if [ ! -z $update ]; then
    echo "updating pipeline"

    [ ! -z $rename ] && pipelineName=$rename #name in case of set in parameter

    az pipelines update \
      --id $pipelineId \
      --name "$pipelineName" \
      --description "$pipelineDescription" \
      --yml-path "$pipelinePath" \
      --branch "$branchName" \

  fi

  #run pipeline if set
  if [ ! -z $run ]; then

    [ -z $silent ] && open='--open '

    if [ -z $parameters ]; then
      # && $pipepars="--parameters \"${parameters}\" "
      az pipelines run \
        --id $pipelineId \
        --branch "$branchName" \
        $open \

    else

      az pipelines run \
        --id $pipelineId \
        --branch "$branchName" \
        --parameters "$parameters" \
        $open \

    fi

  fi

