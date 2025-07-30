return {
	{
		"MeanderingProgrammer/render-markdown.nvim",
		opts = {
			heading = {
				enabled = true,
				atx = true, --icons
				setext = false, --icons
				width = "block",
				icons = { "✶ ", "✶✶ ", "✶✶✶ ", "✶✶✶✶ ", "✶✶✶✶✶ ", "✶✶✶✶✶✶ " },
				backgrounds = {
					false,
					false,
					false,
					false,
					false,
					false,
				},
				foregrounds = {
					"Statement",
					"Statement",
					"Statement",
					"Statement",
					"Statement",
					"Statement",
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
	},
	{
		"mfussenegger/nvim-lint",
		opts = {
			linters = {
				markdownlint = {
					args = { "--disable", "MD013", "--" },
				},
				["markdownlint-cli2"] = {
					args = {
						"--config",
						vim.fn.stdpath("config") .. "/global.markdownlint-cli2.yaml",
						"--",
					},
				},
			},
		},
	},
}
