# let starship_bin = 'starship'
#             # ^'C:\Users\czjabeck\Dev\Scoop\shims\starship.exe' prompt
#
# export-env { load-env {
#     STARSHIP_SHELL: "nu"
#     STARSHIP_SESSION_KEY: (random chars -l 16)
#
#     PROMPT_MULTILINE_INDICATOR: (
#         starship prompt --continuation
#     )
#
#     # Does not play well with default character module.
#     # TODO: Also Use starship vi mode indicators?
#     PROMPT_INDICATOR: ""
#
#     PROMPT_COMMAND: {||
#         # jobs are not supported
#         (
#             starship prompt
#                 --cmd-duration $env.CMD_DURATION_MS
#                 $"--status=($env.LAST_EXIT_CODE)"
#                 --terminal-width (term size).columns
#         )
#     }
#
#     config: ($env.config? | default {} | merge {
#         render_right_prompt_on_last_line: true
#     })
#
#     PROMPT_COMMAND_RIGHT: {||
#         (
#             starship prompt
#                 --right
#                 --cmd-duration $env.CMD_DURATION_MS
#                 $"--status=($env.LAST_EXIT_CODE)"
#                 --terminal-width (term size).columns
#         )
#     }
# }}


$env.STARSHIP_SHELL = "nu"
$env.STARSHIP_SESSION_KEY = (random chars -l 16)

$env.PROMPT_COMMAND = {||
	(
		starship prompt
			--cmd-duration $env.CMD_DURATION_MS
			$"--status=($env.LAST_EXIT_CODE)"
			--terminal-width (term size).columns
	)
}

$env.PROMPT_COMMAND_RIGHT= {||
    (
        starship prompt
            --right
            --cmd-duration $env.CMD_DURATION_MS
            $"--status=($env.LAST_EXIT_CODE)"
            --terminal-width (term size).columns
    )
}
$env.PROMPT_INDICATOR = ""
$env.PROMPT_INDICATOR_VI_INSERT = ": "
$env.PROMPT_INDICATOR_VI_NORMAL = "〉"
$env.PROMPT_MULTILINE_INDICATOR = {||
	(
		starship prompt --continuation 
	)
}
