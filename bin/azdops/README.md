## build c# service

#### 1. chown support scripts
```bash
chmod +x ./ci/scripts/*.sh
```

#### 2. build source code
```bash
./ci/scripts/BuildService.sh build ~/tmp/csbuild
```

#### 3. run unit test
```bash
./ci/scripts/BuildService.sh test
```

#### 4. containerize solution
```bash
./ci/scripts/BuildService.sh containerize ~/tmp/csbuild emp-test
```

#### 5. publish to the repository
as we are using private azure container repository,
there is a prequisite before publish to the repository be inside the ip range and the connect to there for this check chapter bellow

```bash
./ci/scripts/BuildService.sh publish modelproduction.azurecr.io emp-test
```

## Azure Container Registry
add public ip to container registry firewall rule
```bash
az acr network-rule add --name modelproduction --ip-address $(curl ifconfig.me)
```

login to the registry to be able work with it
```bash
az acr login --name modelproduction
```

remove public ip
```bash
az acr network-rule remove --name modelproduction --ip-address $(curl ifconfig.me)
```

## working Azure DevOps pipeline
#### goto to project root
set current project path
```bash
cd ./services/EmployeeOrgStructure
```



#### variable azdops install
install extension
```bash
az extension install --name azure-devops
```

list installed extensions
```bash
az extension list
```

#### creating azdops variable library
create variables in the pipeline
```bash
./ci/helpers/azdops/variables.sh \
```

creating secret value through environment variable
```bash
AZURE_DEVOPS_EXT_PIPELINE_VAR_saPassword=$()

az pipelines variable-group variable create \
  --group-id $groupId \
  --name saPassword \
  --secret True
```

#### creating pipeline
need to have az cli with devops extension

in github create PAT token to be able to get items from the github repo in the pipeline
required items are admin:repo_hook, repo, user)
generated github_PAT_token

to create new pipeline
*entering value to env variable via pass*
```bash
export AZURE_DEVOPS_EXT_GITHUB_PAT=$(pass lego/github_PAT_azdops)

./ci/helpers/azdops/pipeline.sh \
  --create \
  --run \
  --open
```

#### running pipeline
stage changes in ci and helpers commit and run pipeline
--run > run immediately
--open > open in browser

```bash
./ci/helpers/azdops/pipeline.sh \
  --run \
  --open
```

run with pipeline parameters
by default there is no production stage only
this is driven by parameter developStageOnly
default value of the parameter is true
```bash
./ci/helpers/azdops/pipeline.sh \
  --run \
  --open \
  --parameters "developStageOnly=false"
```
*parameters is supported since az extension version 0.23*
