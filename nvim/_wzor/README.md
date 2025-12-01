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

### function

```nu
let lang_merge = {
	| lng:string|
	let file = (open $"./temp/_cleared/($lng).xlsx")
	let tr = ($file
		| get translation
		| skip
		| reduce --fold {} {|i,a|
			$a | merge {$i.column0:$i.column1}
		})

	(open ./solution/mentoring/src/data/translation.yaml
		| merge deep {translation:{$lng:$tr}}
	)
	| to yaml
	| save ./solution/mentoring/src/data/translation.yaml --force

	let email = ($file
		| get email
		| skip
		| reduce --fold {} {|i,a|
			$a | merge {$i.column0:{
				subject:$i.column1
				body:($i.column2 | str replace --all (char crlf) (char lf))
			} }
		})

	{emails:{$lng:$email}}
	| do {|t|
		open ./solution/mentoring/src/data/email.yaml
		| merge deep $t
	} $in
	| to yaml
	| save ./solution/mentoring/src/data/email.yaml  --force
}
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
