### My stories

#### I need to add active remote branch to repos
```bash
gwt branch link <linkbranch>
```
- list remote branches fzf
- create folder
- clone branch
- switch to folder
- switch tmux pane

#### I need to switch to another already linked branch repo *gwt branch switch*
```bash
gwt branch switch <localbranch>
```
- list local branches fzf (if not set)
- switch to folder
- switch tmux pane (if in tmux)

#### I need to create new branch from existing branch
```bash
gwt branch create <existingbranch> <newbranchname>
```
- ask for name
- create folder
- create create remote branch
- switch to folder
- switch tmux pane

#### I need to create new branch from existing branch
```bash
gwt branch rename <existingbranch>
```
- ask for name
- rename folder
- rename remote branch (if exists)
- switch to folder
- switch tmux pane (if exist $GWT_TMUX)

#### I need to archive local linked branch
```bash
gwt branch archive <localbranch>
```
- check if folder archive exists
- move branch local folder to branch folder

#### I need to merge my branch from another brach
```bash
gwt branch merge <mergefrombranch>
```

#### I need to archive switch to branch
```bash
gwt branch switch <localbranch>
```
- check if folder archive exists
- move branch local folder to branch folder

#### I need to archive switch to branch "PRIVATE?"
```bash
gwt branch fullname <localbranch>
```
- get branch from cwd (if not set localbranch)
- return branch with repo

### repo
*local to remote*
init -> push
*remote to local*
clone

#### I need to init new local repo
- [ ]
```bash
gwt repo init [--simple] --path <repopath> --name <reponame>
```

#### I need to push local repo to new remote
- [ ]
```bash
gwt repo push --name <originname> --private <isprivate>
```

#### I need to get remote to local
- [ ]
```bash
gwt repo get --name <originname> --path <repopath>
```

#### I need to print all repos available under location
- [ ]
```bash
gwt repo list [--path rootpath]
```

#### I need to clone get current repo root "PRIVATE?"
- [ ]
```bash
gwt repo rootpath
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

