### My stories
- I need to add active remote branch to repos *gwt link*
    - list branches fzf
    - create folder
    - clone branch
    - switch to folder
    - switch tmux pane
- I need to switch to another branch in repos *gwt switch*
    - list local branches fzf
    - switch to folder
    - switch tmux pane
- I need to create new branch *gwt new*
    - ask for name
    - create folder
    - create create remote branch
    - switch to folder
    - switch tmux pane
- I need to archive local active branch *gwt remove*
    - check if folder archive exists
    - move branch local folder to branch folder


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

