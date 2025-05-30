return {
	"MeanderingProgrammer/render-markdown.nvim",
	opts = {
		heading = {
			enabled = true,
			atx = true, --icons
			setext = false, --icons
			width = "block",
			icons = { "✦ ", "✦✦ ", "✦✦✦ ", "✦✦✦✦ ", "✦✦✦✦✦ ", "✦✦✦✦✦✦ " },
			backgrounds = {
				false,
				false,
				false,
				false,
				false,
				false,
			},
			foregrounds = {
				"DiagnosticError",
				"DiagnosticError",
				"DiagnosticError",
				"DiagnosticError",
				"DiagnosticError",
				"DiagnosticError",
			},
		},
		code = {
			sign = false,
			width = "block",
			border = "thick",
			min_width = 80,
			position = "right",
			language_icon = false,
		},
	},
}
