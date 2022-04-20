#!/bin/bash

#script root dir
sdir=$(dirname "$0")

# scripts variables
source ${sdir}/vars

#calculated variables
root=${sdir}/../../..

#load support fxs
source ${root}/ci/scripts/fxs.sh

# get secrets variables
if ! valid_yaml_secrets2 "${root}/ci/helpers/secrets"; then
  exit 0
fi

#get secrets
eval $(parse_yaml "${root}"/ci/helpers/secrets/environ-secrets.yml)

# name parameters
load_named_args "$@"

repositoryUrl="$repositoryUrlRoot"$(git config --get remote.origin.url | sed -e 's/.*://')
organizationUrl="$azureUrlRoot$organizationName"

secretadd(){
  name=$1
  pass=$2
  groupId=$3

  exists=$(az pipelines variable-group variable list \
    --group-id $groupId \
    --query "saPassword.isSecret")

  #delete if exists
  if [ ! -z $exists ]; then
    az pipelines variable-group variable delete \
      --group-id $groupId \
      --name $name \
      --yes
  fi

  export AZURE_DEVOPS_EXT_PIPELINE_VAR_$name=$pass

  az pipelines variable-group variable create \
    --group-id $groupId \
    --name $name \
    --secret true

}

#list end point --support
# az devops service-endpoint list -o table

#to connect to the project
az devops configure --defaults organization="$organizationUrl" project="$projectName"

groupId=$(az pipelines variable-group list \
  --query "[?name=='${pipelineVariablesGroup}'].id" \
  --output tsv)

#check if created
re='^[0-9]+$'
if ! [[ $groupId =~ $re ]] ; then

  prompt="variablegroup not found and --create argument not found do you want to create pipeline?"
  read -p "$prompt" create

  echo "variablegroup $pipelineVariablesGroup not found will be created"

  #create variablegroup with dummy variable which is needed
  groupId=$(az pipelines variable-group create \
    --name "$pipelineVariablesGroup" \
    --query "id" \
    --variable "dummy=null" \
    --output tsv)

  secretadd 'saPassword' "$secrets_sa_password" $groupId
  secretadd 'suPassword' "$secrets_service_user_password" $groupId

  #remove dummy variable
  az pipelines variable-group variable delete \
      --group-id $groupId \
      --name dummy \
      --yes

fi
