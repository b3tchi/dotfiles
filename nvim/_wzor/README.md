# slime like addon for neovim under tmux

working right now with nushell

can handle multiline
can should wait until code new command line is entered
for some long interactive stuff this could maybe will not work need to be tested
whole logic is capturing-pane input

```nu
let x = '
test
ain
uuu'
let b = (input 'abec')

echo $b
```
