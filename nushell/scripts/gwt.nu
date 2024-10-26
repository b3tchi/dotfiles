module gwt {

  def data [] {
    {
      b3tchi: {
        user: b3tchi
        email: beckaja1@gmail.com
        domain: github.com
      }
    }
  }

  def profiles [] { (data | columns ) }

  def vars [
    profile:string@profiles
    property:string
    ] {
    data | get $profile | get $property
  }

  # init local bare repo from defiend path
  export def 'repo init' [
      path?: string #define root location of repository default PWD 
      --init-commit: string = 'repo creation commit' #initial commit message
    ] {

    let $current_path = (if $path == null {$env.PWD} else {$path}) 

    let main_path = $current_path | path join main
    let bare_path = $current_path | path join default

    #create ne repository
    git init --bare $bare_path --initial-branch=main
    git $"--git-dir=($bare_path)" worktree add $main_path

    #copy data
    touch ( $main_path | path join README.md )
    ls -a $current_path | where name !~ main | where name !~ default | each { |item|
      print $"move ($item.name)"
      mv -fv $item.name $main_path
    }

    #add all items
    git $"--git-dir=($bare_path)" $"--work-tree=($main_path)" add '*'
    git $"--git-dir=($bare_path)" $"--work-tree=($main_path)" commit -m $init_commit
  }

  def scopes [] { ["private", "internal", "public"] }

  # create remote repo push to local repository
  export def 'repo push' [
      profile: string@profiles #users current github user
      scope: string@scopes # accesibility of the repository
      --path: string #repository root path
      --name: string #name of the repository an github
      --owner: string #repository owner
    ] {

    let user = (vars $profile user )
    # print $user
    # return 

    let path = (if $path == null { $env.PWD } else {$path})

    let git_dir = ($path | path join default)
    print $git_dir
    if (($git_dir | path exists) == false) {
      print "this in working from only from root directory"
      return
    }

    let home_path = ( if $nu.os-info.name == "windows" { $env.USERPROFILE } else { $env.HOME } )

    let acc = $"github.com-($user)"
    if ((($home_path | path join .ssh config.d $acc) | path exists) == false) {
      print "cannot find user ssh key"
      return
    }

    let gh_user = (gh api user | from json | get login)
    if $user != $gh_user {
      print "gh currently log as diffrent user"
      return
    }

    let owner = (if $owner == null {$user} else {$owner})
    let name = (if $name == null {$path | path basename} else {$name})

    let repos_root = ( if $nu.os-info.name == "windows" { $env.USERPROFILE | path join Dev Repositories } else { $env.HOME | path join repos } )
    let repo_path = $repos_root | path join $owner $name
    # mkdir -p 
    print {
      'repo_path': $repo_path,
      'local path': $path,
      'gh user': $gh_user,
    } | to text

    if ($repo_path | path exists) {
      print "local repo path already exists"
      return
    }

    #TBD gh repo create, move to repos , git remote add origin, push main 
  }

  def remote_names [context: string] {

    let last_args = $context | split row ' ' | last 2

    let profile = $last_args | first 
    let user = (vars $profile user)
    let filter = (if ($last_args | last) == '' {''} else { $last_args | last })
    # let filter = (if $context =~ '--filter' {$context | str replace -r '.* --filter (.*?) .*' '${1}'} else {''})
    let owner = (if $context =~ '--owner' { $context | str replace -r '.* --owner (.*?) .*' '${1}'} else {''})

    let gh_user = (gh api user | from json | get login)
    if ($user != $gh_user) {
      print $"gh currently log under different user ($gh_user)"
      return
    }

    mut args = []
    if $filter != '' { $args = ($args | append $filter)}
    if $owner != '' { $args = ($args | append [ --owner $owner])}
    let args = ($args | append [ --json name])

    gh search repos ...$args | from json | get name
  }

  #get repository from remote repo
  export def 'repo get' [
      --owner: string #repository owner
      # --filter: string #pre-filter list
      profile: string@profiles #users current github user
      name: string@remote_names #name of the repository an github
    ] {

    let domain = (vars $profile domain)
    let email = (vars $profile email)
    let user = (vars $profile user)
    # let os = (sys host).name

    let repos_root = ( if $nu.os-info.name == "windows" { $env.USERPROFILE | path join Dev Repositories } else { $env.HOME | path join repos } )

    let gh_user = (gh api user | from json | get login)
    if ($user != $gh_user) {
      print $"gh currently log under different user ($gh_user)"
      return
    }

    let owner = (if $owner == null { $user } else {$owner})
    let default_branch = (gh repo view $"($owner)/($name)" --json defaultBranchRef | from json | get defaultBranchRef.name)
    let current_path =  $repos_root | path join $owner $name
    let branch_path = $current_path | path join $default_branch
    let bare_path = $current_path | path join default

    # create ne repository
    git init --bare $bare_path $"--initial-branch=($default_branch)"
    git $"--git-dir=($bare_path)" config user.name $user
    git $"--git-dir=($bare_path)" config user.email $email

    git $"--git-dir=($bare_path)" remote add origin $"git@($domain)-($user):($owner)/($name).git"
    git $"--git-dir=($bare_path)" fetch

    git $"--git-dir=($bare_path)" worktree add $branch_path $"origin/($default_branch)"
    cd $branch_path # for some reason i can't use --work-tree=... checkout will not attach to branch
    git checkout -b $default_branch
    git pull --set-upstream origin $default_branch
  }

  # register user ssh token
  export def 'user register' [
      profile:string@profiles # select which profile to register
      --ssh-path:string #already existing registered git registered key
    ] {

    let domain = (vars $profile domain)
    let email = (vars $profile email)
    let user = (vars $profile user)

    let gh_user = (gh api user | from json | get login)
    if ($user != $gh_user) {
      print "gh currently log as diffrent user"
      return
    }

    let stamp = date now | format date %y%m%d
    let os = (sys host).name
    let host = (sys host).hostname
    let coding = 'ed25519'

    let uniq_name = [$stamp $user $host $os $coding ] | str join '_'

    let root_path = ( if $nu.os-info.name == "windows" { $env.USERPROFILE } else { $env.HOME } )
    let file = (if ( $ssh_path | is-empty ) { $root_path | path join .ssh $uniq_name } else { $ssh_path | path expand })
    # print $file
    
    if ($ssh_path | is-empty) {
      ssh-keygen -t $coding -C $email -f $file -N ''
      gh ssh-key add $"($file).pub" --title $uniq_name
    }

    #saving global
    "Include config.d/*" | save --force ($root_path | path join .ssh config)

    #saving local file
    let config_dir = $root_path | path join .ssh config.d
    mkdir $config_dir

    let config_file = $config_dir | path join ( [$domain $user] | str join '-' )
    let config = $"Host ($domain)-($user)
      HostName ($domain)
      User git
      IdentityFile ($file)"

    $config | save --force $config_file
  }

	def origin_branches [ 
		] {
		git ls-remote --heads origin | from tsv --noheaders | get column2 | each { |it| ($it | str replace 'refs/heads/' '')}
	}
  # create new branch
	export def 'branch create' [
			name:string #new branch name
			from:string@origin_branches #select from branch
			--path:string #repository root path
		] {

		let path = (if $path == null { $env.PWD })
		let git_dir = git worktree list 
			| split row -r '\n' 
			| where $it =~ '(bare)' 
			| str replace -r default.* ''

		if (($git_dir | path exists) == false) {
			print "this in working from only from branch directory"
			return
		}
		let confirmation = ( [ok cancel] | input list $"create new branch ($name) from branch ($from)?" ) 

		if $confirmation == cancel { 
			return
		}

# git worktree list | from tsv --noheaders | get column2 | each { |it| ($it | str replace 'refs/heads/' '')}

		let repo_path = $path | path dirname
		let branch_path =  $repo_path | path join $name

		if ($branch_path | path exists) == true {
			print $"location with branch exists ($branch_path)"
			return
		}

		mkdir $branch_path

		git worktree add -b $name $branch_path $"origin/($from)"
		cd $branch_path
		git push -u origin $name
# git branch switch --name $name
	}

	def local_branches [ 
		] {
# git worktree list | from tsv --noheaders | get column2 | each { |it| ($it | str replace 'refs/heads/' '')}
		git worktree list | split row -r '\n' | where $it !~ '(bare)' | str replace -r '.*\[' '' | str replace  -r '\]' ''
	}

	export def 'branch remove' [
			name:string@local_branches #select from branch
		] {

# let git_dir = ($path | path join .. default)
		let git_dir = git worktree list 
			| split row -r '\n' 
			| where $it =~ '(bare)' 
			| str replace -r default.* ''

		if ($git_dir | path exists) == false {
			print "this in working from only from branch directory"
			return
		}

		let confirmation = ( [ok cancel] | input list $"remove local branch ($name) from repository?" )

		if $confirmation == cancel { 
			return
		}

		git worktree remove --force $name
	}

  #link branch from origin
  export def 'branch link' [
      name:string@origin_branches #select from origin branches
      --path:string #repository root path
    ] {

    let path = (if $path == null { $env.PWD } else {$path})

    let git_dir = git worktree list 
      | split row -r '\n' 
      | where $it =~ '(bare)' 
      | str replace -r default.* ''

    if (($git_dir | path exists) == false) {
      print "this in working from only from branch directory"
      return
    }

    let repo_path = $path | path dirname

    let $branch_name = if $nu.os-info.name == "windows" { $name | str replace '/' '\' } else { $name }
   
    print $branch_name
  
    let branch_path =  $repo_path | path join $branch_name

    if ($branch_path | path exists) == true {
      print $"location with branch exists ($branch_path)"
      return
    }

    print $branch_path
    mkdir $branch_path

    # git worktree add -b $branch_path $"origin/($name)"
    git worktree add $branch_path $"origin/($name)" #this is working on windows with -b it fails
    cd $branch_path
    git checkout $name
  }

  export def increment_version [
      version:string
      type:string
    ] {
    # Split the version string into a table where each column is a version part.
    let version_parts = ($version | split row .)
    mut major = ($version_parts.0 | into int )
    mut minor = ($version_parts.1 | into int )
    mut patch = ($version_parts.2 | into int )
    
    print $version
    # Match the `type` and increment the relevant part, resetting others as needed.
    match $type {
      'major' => {
        $major = ($major + 1)
        $minor = 0
        $patch = 0
      }
      'minor' => {
        $minor = ($minor + 1)
        $patch = 0
      }
      'patch' => {
        $patch = ($patch + 1)
      }
      _ => { # fallback in case of an unexpected type
        error $"Unexpected version increment type: ($type)" 
        exit
      }
    }

    # Output the final version string.
    return ([$major $minor $patch] | str join .)
  }

  # version monorepo folders
  export def 'branch version' [
      # commit?:string #define commit is relate to othewise use HEAD
      root?:string #commit root path in repo
    ] {

    let commit = 'HEAD'
    # let commit = (if $commit == null { HEAD } else {$commit})

    #mvp fixed structure container_code/project/component/
    let changed_subdirs = if $commit == 'HEAD' {
      (git diff  --name-only @{u}..HEAD 
        | str trim | split row -r \n 
        | where $it =~ '.*/.*/.*/.*'
        | each {|e| ($e | str replace --regex '(.*?)/(.*?)/(.*?)/.*' '${2}/${3}')} 
        | uniq
      )
    }

    #
    # else {
    # 	(git diff --name-only $commit^{commit} $commit^{commit}~1 $root_dir | awk -F'/' '{print $2 "/" $3}' | sort -u)
    #  }

    let commit_long = (git rev-parse HEAD)

    # print $resp
    mut new_tags = []

    for $subdir in $changed_subdirs {

      print $subdir
      let describe_output = (git tag --points-at $commit_long | where $it =~ $subdir )
      if ( $describe_output | is-empty ) == false {
        print $"Current commit is already tagged for ($subdir), skipping."
        continue
      }

      mut latest_tag = (git describe --tags --match $"($subdir)/*" --abbrev=0 | split row '/' | last)

      if $latest_tag == null { $latest_tag = '0.0.0' }

      print $latest_tag

      let resp = ([
          $"major (increment_version $latest_tag major)"
          $"minor (increment_version $latest_tag minor)"
          $"patch (increment_version $latest_tag patch)"
          $"cancel"
        ] | input list $"select what change is made ($subdir) version ($latest_tag)" --index
      )

      let action = match $resp {
        0 => [[change tag]; [major $"($subdir)/(increment_version $latest_tag major)"]]
        1 => [[change tag]; [minor $"($subdir)/(increment_version $latest_tag minor)"]]
        2 => [[change tag]; [patch $"($subdir)/(increment_version $latest_tag patch)"]]
        _ => continue
      }
        
      $new_tags = ( $new_tags | append $action )

      print $"change: ($action.change) new_tag: ($action.tag)"

    }

    if ($new_tags | length) == 0 { 
        print "No actions to perform. Exiting..."
        return
    }

    #confirm action
    let confirmation = ( [confirm cancel] | input list 'Please confirm new tags')

    if $confirmation == 'cancel' {
      print "Operation cancelled by user"
      return
    }

    for $tag in $new_tags {
      git tag $"($tag)"
      print $"Tag created: ($tag.tag)"
    }
  }
}

