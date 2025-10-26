# slime like addon for neovim under tmux

working right now with nushell

can handle multiline
can should wait until code new command line is entered
for some long interactive stuff this could maybe will not work need to be tested
whole logic is capturing-pane input

## Chapter scope

### mulitple commands

```nu
print '1'
print '2'
```

```nu
print '
4
1
1
1
2
'
```

### texts

```nu
print '1'
print '2'
print '3'
print '4'
```

```nu
let x = '
test
ain
uuu'

echo $x
```

### waiting for long commands

```nu
sleep 5sec
print 'x'
```

### input

> [!NOTE]
> TBD not yet implemented

```nu
let _input = (input "enter text")
print $_input
```
