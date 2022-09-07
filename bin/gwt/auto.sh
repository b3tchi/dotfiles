mainbr="main"
devbr="develop"

#owerwritable
[[ -z $rootpath ]] && rootpath="$HOME/repos"

tmux_switch(){
	# sessionname=$selected
if [[ -d $path ]]; then

	tmux_running=$(pgrep tmux)

	if [[ -z $TMUX ]] && [[ -z $tmux_running ]]; then
		tmux new-session -s $sessionname -c $path
		exit 0
	fi

	if ! tmux has-session -t $sessionname 2> /dev/null; then
		tmux new-session -ds $sessionname -c $path
	fi

	tmux switch-client -t $sessionname

fi
}
