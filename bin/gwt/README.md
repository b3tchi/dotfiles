### My stories

[toc]

#### I need to add active remote branch to repos
```bash
gwt link <linkbranch>
```
- list branches fzf
- create folder
- clone branch
- switch to folder
- switch tmux pane

#### I need to switch to another already linked branch repo *gwt switch*
```bash
gwt switch <localbranch>
```
- list local branches fzf
- switch to folder
- switch tmux pane

#### I need to create new branch from existing branch
```bash
gwt create <existingbranch> <newbranchname>
```
- ask for name
- create folder
- create create remote branch
- switch to folder
- switch tmux pane

#### I need to archive local linked branch
```bash
gwt remove <localbranch>
```
- check if folder archive exists
- move branch local folder to branch folder

#### I need to merge my branch from another brach
```bash
gwt merge <mergefrombranch>
```

#### I need to init new local repo
```bash
gwt repo init <reponame> <repopath>
```

#### I need to push local repo to remote
```bash
gwt repo create <originname> <isprivate>
```

#### I need to clone remote to local
```bash
gwt repo clone <originname> <repopath>
```

#### I need to pull request my branch to another brach
#### I need to create add new ssh-key
#### I need to increase latest tag by Maj.Min.Build by flag (Maj|Min|Build)

### Snippets
get only active remote branches
```bash
git ls-remote --heads origin | sed -e 's/^.*heads\///'
```
list all branches with details -vva
```bash
git branch -vva
```

get active branch name
```bash
git branch | grep "*" | sed -e 's/* //'
```


get all active remote branches without already active
```bash
fx1(){
    activeremote=$(git ls-remote --heads origin | sed -e 's/^.*heads\///')
    activelocal=$(git worktree list | sed -e 's/^.*\[//' | sed -e 's/\]$//')

    comm -23 <(tr ' ' $'\n' <<< $activeremote | sort) <(tr ' ' $'\n' <<< $activelocal | sort)
}
```

get repo root
```bash
git worktree list | grep 'master' | sed -e 's/\/master.*//'
```

pick different only from second item
```bash
before="1029 184613 10200 83756 63054"
after="184613 10200 84192 83756 63054"

comm -23 <(tr ' ' $'\n' <<< $after | sort) <(tr ' ' $'\n' <<< $before | sort)
```

