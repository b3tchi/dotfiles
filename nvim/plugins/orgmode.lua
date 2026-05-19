return {
	"nvim-orgmode/orgmode",
	dependencies = {
		"b3tchi/headlines.nvim", --strip other langueages then org
		dependencies = "nvim-treesitter/nvim-treesitter",
		ft = { "org", "markdown" },
		config = function()
			require("headlines").setup({
				markdown = {
					query = vim.treesitter.query.parse(
						"markdown",
						[[
						(atx_heading [
							(atx_h1_marker)
							(atx_h2_marker)
							(atx_h3_marker)
							(atx_h4_marker)
							(atx_h5_marker)
							(atx_h6_marker)
						] @headline)
						(thematic_break) @dash
						(fenced_code_block) @codeblock
						(block_quote_marker) @quote
						(block_quote (paragraph (inline (block_continuation) @quote)))
						(block_quote (paragraph (block_continuation) @quote))
					]]
					),
					headline_highlights = {
						"MdHeadline1",
						"MdHeadline2",
						"MdHeadline3",
						"MdHeadline4",
						"MdHeadline5",
						"MdHeadline6",
					},
					bullet_highlights = {
						"MdHeadline1Bullet",
						"MdHeadline2Bullet",
						"MdHeadline3Bullet",
						"MdHeadline4Bullet",
						"MdHeadline5Bullet",
						"MdHeadline6Bullet",
					},
					bullets = { "✶", "✶✶", "✶✶✶", "✶✶✶✶", "✶✶✶✶✶", "✶✶✶✶✶✶" },
					codeblock_highlight = false,
					dash_highlight = "Dash",
					dash_string = "-",
					quote_highlight = "Quote",
					quote_string = "┃",
					fat_headlines = false,
				},
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

			-- vim.cmd([[highlight OrgHeadline1 guibg=#211e2d guifg=#ff9e64 gui=bold]])
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

			-- markdown headlines: text white (matches bold), bullets purple
			vim.cmd([[highlight MdHeadline1 guifg=#e6ebf5 gui=bold]])
			vim.cmd([[highlight MdHeadline2 guifg=#e6ebf5 gui=bold]])
			vim.cmd([[highlight MdHeadline3 guifg=#e6ebf5 gui=bold]])
			vim.cmd([[highlight MdHeadline4 guifg=#e6ebf5 gui=bold]])
			vim.cmd([[highlight MdHeadline5 guifg=#e6ebf5 gui=bold]])
			vim.cmd([[highlight MdHeadline6 guifg=#e6ebf5 gui=bold]])

			vim.cmd([[highlight MdHeadline1Bullet guifg=#ff9e64 gui=bold]])
			vim.cmd([[highlight MdHeadline2Bullet guifg=#ff9e64 gui=bold]])
			vim.cmd([[highlight MdHeadline3Bullet guifg=#ff9e64 gui=bold]])
			vim.cmd([[highlight MdHeadline4Bullet guifg=#ff9e64 gui=bold]])
			vim.cmd([[highlight MdHeadline5Bullet guifg=#ff9e64 gui=bold]])
			vim.cmd([[highlight MdHeadline6Bullet guifg=#ff9e64 gui=bold]])
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
