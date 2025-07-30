return {
	"nvim-orgmode/orgmode",
	dependencies = {
		"lukas-reineke/headlines.nvim",
		dependencies = "nvim-treesitter/nvim-treesitter",
		config = function()
			require("headlines").setup({
				markdown = false,
				org = {
					query = vim.treesitter.query.parse(
						"org",
						[[
						(headline (stars) @headline)
						(
							(expr) @dash
							(#match? @dash "^-----+$")
						)
						(block
							name: (expr) @_name
							contents: (contents) @codeblock
							(#match? @_name "(SRC|src|EXAMPLE|example)")
						)
						;inline blocks
						;((expr) @quote
						;	(#match? @quote "[~].+[~]")
						;)
						(paragraph . (expr) @quote
							(#eq? @quote ">")
						)
					]]
					),
					-- headline_highlights = false,
					headline_highlights = {
						"OrgHeadline1",
						"OrgHeadline2",
						"OrgHeadline3",
						"OrgHeadline4",
						"OrgHeadline5",
						"OrgHeadline6",
					},
					bullet_highlights = {
						"OrgHeadline1Bullet",
						"OrgHeadline2Bullet",
						"OrgHeadline3Bullet",
						"OrgHeadline4Bullet",
						"OrgHeadline5Bullet",
						"OrgHeadline6Bullet",
					},
					bullets = { "✦", "✦✦", "✦✦✦", "✦✦✦✦", "✦✦✦✦✦", "✦✦✦✦✦✦" },
					codeblock_highlight = "CodeBlock",
					dash_highlight = "Dash",
					dash_string = "-",
					quote_highlight = "Quote",
					-- inlineblock_highlight = "OrgInlineBlock",
					quote_string = "┃",
					fat_headlines = false,
					-- fat_headline_upper_string = "▄",
					-- fat_headline_lower_string = "▀",
				},
			})

			-- vim.cmd([[highlight OrgHeadline1 guibg=#211e2d guifg=#bb9af7 gui=bold]])
			vim.cmd([[highlight OrgHeadline1 guifg=#bb9af7 gui=bold]])
			vim.cmd([[highlight OrgHeadline2 guifg=#bb9af7 gui=bold]])
			vim.cmd([[highlight OrgHeadline3 guifg=#bb9af7 gui=bold]])
			vim.cmd([[highlight OrgHeadline4 guifg=#bb9af7 gui=bold]])
			vim.cmd([[highlight OrgHeadline5 guifg=#bb9af7 gui=bold]])
			vim.cmd([[highlight OrgHeadline6 guifg=#bb9af7 gui=bold]])

			vim.cmd([[highlight OrgHeadline1Bullet guifg=#ff7577 gui=bold]])
			vim.cmd([[highlight OrgHeadline2Bullet guifg=#ff7577 gui=bold]])
			vim.cmd([[highlight OrgHeadline3Bullet guifg=#ff7577 gui=bold]])
			vim.cmd([[highlight OrgHeadline4Bullet guifg=#ff7577 gui=bold]])
			vim.cmd([[highlight OrgHeadline5Bullet guifg=#ff7577 gui=bold]])
			vim.cmd([[highlight OrgHeadline6Bullet guifg=#ff7577 gui=bold]])
		end,
	},
	event = "VeryLazy",
	ft = { "org" },
	config = function()
		-- Setup orgmode
		require("orgmode").setup({
			org_agenda_files = "~/orgfiles/**/*",
			org_startup_folded = "content",
			org_default_notes_file = "~/orgfiles/refile.org",
			mappings = {
				org = {
					org_do_demote = false,
					org_do_promote = false,
				},
			},
		})

		-- NOTE: If you are using nvim-treesitter with ~ensure_installed = "all"~ option
		-- add ~org~ to ignore_install
		-- require("nvim-treesitter.configs").setup({
		-- 	ensure_installed = "all",
		-- 	ignore_install = { "org" },
		-- })
	end,
}
