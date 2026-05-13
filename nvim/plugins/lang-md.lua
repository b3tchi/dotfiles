-- Let blink continue completion through `#` and `[` so wikilink/tag triggers
-- don't break the word boundary mid-typing. Without this, blink's keyword
-- match stops at `#`/`[` and aborts the popup as soon as you type the trigger.
vim.api.nvim_create_autocmd("FileType", {
	pattern = "markdown",
	callback = function()
		vim.opt_local.iskeyword:append({ "#", "[" })
	end,
})

return {
	{
		"neovim/nvim-lspconfig",
		opts = {
			servers = {
				marksman = { enabled = false },
				markdown_oxide = {
					mason = false,
					cmd = { "markdown-oxide" },
					filetypes = { "markdown" },
					root_markers = { ".moxide.toml", ".obsidian", ".git" },
					capabilities = {
						workspace = {
							didChangeWatchedFiles = { dynamicRegistration = true },
						},
					},
				},
			},
		},
	},
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
