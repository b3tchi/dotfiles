-- Let blink continue completion through `#` and `[` so wikilink/tag triggers
-- don't break the word boundary mid-typing. Without this, blink's keyword
-- match stops at `#`/`[` and aborts the popup as soon as you type the trigger.
vim.api.nvim_create_autocmd("FileType", {
	pattern = "markdown",
	callback = function()
		vim.opt_local.iskeyword:append({ "#", "[" })
	end,
})

-- Gray any tag (`<...>` / `</...>`) at the beginning of a line in markdown,
-- regardless of whether treesitter html injection caught it. matchadd is
-- window-local and draws on top of treesitter extmarks. FileType + BufWinEnter
-- + WinEnter together cover: opening a buffer, splitting, switching windows.
local md_match_group = vim.api.nvim_create_augroup("MdTagFallback", { clear = true })
vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinEnter" }, {
	group = md_match_group,
	callback = function()
		if vim.bo.filetype ~= "markdown" then
			return
		end
		for _, m in ipairs(vim.fn.getmatches()) do
			if m.group == "MdTagFallback" then
				return
			end
		end
		pcall(vim.fn.matchadd, "MdTagFallback", [[^\s*\zs</\?[A-Za-z][A-Za-z0-9_:.\-]*\%(\s[^>]*\)\?/\?>]])
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
				enabled = false, -- headings handled by headlines.nvim (see orgmode.lua)
				atx = true, --icons
				setext = false, --icons
				width = "block",
				icons = { "✶ ", "✶✶ ", "✶✶✶ ", "✶✶✶✶ ", "✶✶✶✶✶ ", "✶✶✶✶✶✶ " },
				backgrounds = {
					"Statement",
					"Statement",
					"Statement",
					"Statement",
					"Statement",
					"Statement",
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
				highlight_language = "RenderMarkdownLanguage",
			},
			bullet = {
				icons = { "•", "•", "•", "•" },
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
