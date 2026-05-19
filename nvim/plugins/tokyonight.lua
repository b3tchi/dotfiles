return {
	"folke/tokyonight.nvim",
	lazy = false,
	priority = 1000,
	config = function()
		require("tokyonight").setup({
			-- your configuration comes here
			-- or leave it empty to use the default settings
			-- style = "storm", -- The theme comes in three styles, `storm`, `moon`, a darker variant `night` and `day`
			style = "night", -- The theme comes in three styles, `storm`, `moon`, a darker variant `night` and `day`
			light_style = "day", -- The theme is used when the background is set to light
			transparent = false, -- Enable this to disable setting the background color
			terminal_colors = true, -- Configure the colors used when opening a `:terminal` in [Neovim](https://github.com/neovim/neovim)
			styles = {
				-- Style to be applied to different syntax groups
				-- Value is any valid attr-list value for `:help nvim_set_hl`
				comments = { italic = true },
				keywords = { italic = true },
				functions = {},
				variables = {},
				-- Background styles. Can be "dark", "transparent" or "normal"
				sidebars = "normal", -- style for sidebars, see below
				floats = "dark", -- style for floating windows
			},

			sidebars = { "qf", "help", "neo-tree", "aerial" }, -- Set a darker background on sidebar-like windows. For example: `["qf", "vista_kind", "terminal", "packer"]`
			day_brightness = 0.3, -- Adjusts the brightness of the colors of the **Day** style. Number between 0 and 1, from dull to vibrant colors
			hide_inactive_statusline = false, -- Enabling this option, will hide inactive statuslines and replace them with a thin border instead. Should work with the standard **StatusLine** and **LuaLine**.
			dim_inactive = false, -- dims inactive windows
			lualine_bold = false, -- When `true`, section headers in the lualine theme will be bold

			--- You can override specific color groups to use other groups or a hex color
			--- function will be called with a ColorScheme table
			-----@param colors ColorScheme
			--on_colors = function(colors) end,

			--- You can override specific highlights to use other groups or a hex color
			--- function will be called with a Highlights and ColorScheme table
			-----@param highlights Highlights
			on_highlights = function(hl, c)
				local prompt = "#2d3149"
				-- hl.TelescopeNormal = { fg = c.fg_dark }
				hl.TelescopeNormal = { bg = c.bg_dark, fg = c.fg_dark }
				hl.TelescopeBorder = { bg = c.bg_dark, fg = c.bg_dark }
				hl.TelescopePromptNormal = { bg = prompt }
				hl.TelescopePromptBorder = { bg = prompt, fg = prompt }
				hl.TelescopePromptTitle = { bg = prompt, fg = prompt }
				hl.TelescopePreviewTitle = { bg = c.bg_dark, fg = c.bg_dark }
				hl.TelescopePreviewNormal = { fg = c.fg_dark }
				hl.TelescopeResultsTitle = { bg = c.bg_dark, fg = c.bg_dark }

				--transparent background
				-- hl.Normal = { fg = "#7aa2f7" }
				-- hl.NeoTreeNormal = { fg = "#7aa2f7" }
				-- hl.NeoTreeNormal = { bg = c.bg_dark, fg = c.fg_dark }
				-- hl.NeoTreeNormalNC = { bg = c.bg_dark, fg = c.fg_dark }

				--column line with numbers
				local lineNr = "#1a1b26"
				-- hl.CursorLineNr = { fg = "#ff9e64", bg = lineNr }
				hl.LineNr = { fg = "#3b4261" }
				hl.SignColumn = {}
				-- hl.SignColumnSB = { bg = lineNr }
				-- hl.SignColumn = { bg = lineNr }
				-- hl.UfoCursorFoldedLine = { fg = "#3b4261", bg = lineNr }
				-- hl.CursorLineFold = { fg = "#3b4261", bg = lineNr }
				-- hl.FoldColumn = { fg = "#3b4261", bg = lineNr }
				--
				-- hl.GitSignsAdd = { fg = "#266d6a", bg = lineNr }
				-- hl.GitSignsChange = { fg = "#536c9e", bg = lineNr }
				-- hl.GitSignsDelete = { fg = "#b2555b", bg = lineNr }
				--
				-- hl.DiagnosticSignWarn = { fg = "#e0af68", bg = lineNr }
				-- hl.DiagnosticSignInfo = { fg = "#0db9d7", bg = lineNr }
				-- hl.DiagnosticSignHint = { fg = "#1abc9c", bg = lineNr }
				-- hl.DiagnosticSignError = { fg = "#db4b4b", bg = lineNr }
				--
				-- --separator between panes same as LineNr
				hl.WinSeparator = { fg = lineNr, bg = lineNr }

				-- inline `code` in markdown: dark bg + light green fg, mirror fenced block style
				hl.RenderMarkdownCodeInline = { bg = "#1a1b26", fg = "#9ece6a" }
				--
				-- --foldes
				hl.Folded = { bg = "#16161e", fg = "#ff9e64" } --fold-ufo (orange line when folded)
				hl.UfoFoldedEllipsis = { bg = "#16161e", fg = "#ff9e64" }

				-- markdown: whiter heading TEXT (icons stay purple via Statement in render-markdown opts)
				local white = "#e6ebf5"
				hl["@markup.heading"] = { fg = white, bold = true }
				hl["@markup.heading.1"] = { fg = white, bold = true }
				hl["@markup.heading.2"] = { fg = white, bold = true }
				hl["@markup.heading.3"] = { fg = white, bold = true }
				hl["@markup.heading.4"] = { fg = white, bold = true }
				hl["@markup.heading.5"] = { fg = white, bold = true }
				hl["@markup.heading.6"] = { fg = white, bold = true }
				hl["@markup.heading.1.markdown"] = { fg = white, bold = true }
				hl["@markup.heading.2.markdown"] = { fg = white, bold = true }
				hl["@markup.heading.3.markdown"] = { fg = white, bold = true }
				hl["@markup.heading.4.markdown"] = { fg = white, bold = true }
				hl["@markup.heading.5.markdown"] = { fg = white, bold = true }
				hl["@markup.heading.6.markdown"] = { fg = white, bold = true }
				hl.markdownH1 = { fg = white, bold = true }
				hl.markdownH2 = { fg = white, bold = true }
				hl.markdownH3 = { fg = white, bold = true }
				hl.markdownH4 = { fg = white, bold = true }
				hl.markdownH5 = { fg = white, bold = true }
				hl.markdownH6 = { fg = white, bold = true }
				-- heading TEXT (extmark line region) painted white via custom hl set in foregrounds
				hl.MdHeadingText = { fg = white, bold = true }
				-- heading icons (✶) stay purple — virt_text uses RenderMarkdownH* hl
				local purple = "#bb9af7"
				hl.RenderMarkdownH1 = { fg = purple, bold = true }
				hl.RenderMarkdownH2 = { fg = purple, bold = true }
				hl.RenderMarkdownH3 = { fg = purple, bold = true }
				hl.RenderMarkdownH4 = { fg = purple, bold = true }
				hl.RenderMarkdownH5 = { fg = purple, bold = true }
				hl.RenderMarkdownH6 = { fg = purple, bold = true }
				-- markdown table: header + frame orange
				local orange = "#ff9e64"
				hl.RenderMarkdownTableHead = { fg = orange, bold = true }
				hl.RenderMarkdownTableRow = { fg = orange }
				hl.RenderMarkdownTableFill = { fg = orange }
				-- bold text
				hl["@markup.strong"] = { fg = "#e6ebf5", bold = true }
				hl["@markup.strong.markdown_inline"] = { fg = "#e6ebf5", bold = true }

				-- diagnostics: colored undercurls (sp = special color)
				hl.DiagnosticUnderlineError = { undercurl = true, sp = "#db4b4b" }
				hl.DiagnosticUnderlineWarn = { undercurl = true, sp = "#e0af68" }
				hl.DiagnosticUnderlineInfo = { undercurl = true, sp = "#0db9d7" }
				hl.DiagnosticUnderlineHint = { undercurl = true, sp = "#1abc9c" }
				hl.SpellBad = { undercurl = true, sp = "#db4b4b" }
				hl.SpellCap = { undercurl = true, sp = "#e0af68" }
				hl.SpellLocal = { undercurl = true, sp = "#0db9d7" }
				hl.SpellRare = { undercurl = true, sp = "#1abc9c" }

				-- markdown inline html/xml tags: MdTagFallback (matchadd) handles BOL tags only,
				-- so we don't override @tag.html globally — inline tags keep tokyonight html colors.
				local tag_color = "#565f89"
				hl.MdTagFallback = { fg = tag_color }

				-- code block language label (e.g. ```lua) green — treesitter paints the
				-- in-source word, render-markdown paints the right-border virt_text label
				hl.RenderMarkdownLanguage = { link = "Comment" }
				hl.RenderMarkdownCodeLanguage = { link = "Comment" }
				hl["@label.markdown"] = { link = "Comment" }
				hl["@string.special.markdown"] = { link = "Comment" }
				hl["@property.markdown"] = { link = "Comment" }

				-- unchecked todo `- [ ]` orange, regular weight
				local orange2 = "#ff9e64"
				hl.RenderMarkdownUnchecked = { fg = orange2 }
				hl.RenderMarkdownTodo = { fg = orange2 }
				hl["@markup.list.unchecked"] = { fg = orange2 }
				hl["@markup.list.unchecked.markdown"] = { fg = orange2 }
			end,
		})

		-- vim.api.nvim_set_hl(0, "ActiveWindow", { bg = "" })
		-- vim.api.nvim_set_hl(0, "InactiveWindow", { bg = "#222436" })
		--
		-- DONE vim.api.nvim_set_hl(0, "Normal", { fg = "#7aa2f7" })
		-- DONE vim.api.nvim_set_hl(0, "NeoTreeNormal", { fg = "#7aa2f7" })
		--
		-- vim.api.nvim_set_hl(0, "DiffViewDiffAddAsDelete", { bg = "#37222c" })
		--
		-- DONE vim.api.nvim_set_hl(0, "SignColumnSB", { bg = "#1a1b26" })
		-- DONE vim.api.nvim_set_hl(0, "SignColumn", { bg = "#1a1b26" })
		--
		-- DONE vim.api.nvim_set_hl(0, "CursorLineNr", { fg = "#ff9e64", bg = "#1a1b26" })
		-- DONE vim.api.nvim_set_hl(0, "LineNr", { fg = "#3b4261", bg = "#1a1b26" })
		--
		-- DONE im.api.nvim_set_hl(0, "GitSignsAdd", { fg = "#266d6a", bg = "#1a1b26" })
		-- DONE im.api.nvim_set_hl(0, "GitSignsChange", { fg = "#536c9e", bg = "#1a1b26" })
		-- DONE im.api.nvim_set_hl(0, "GitSignsDelete", { fg = "#b2555b", bg = "#1a1b26" })
		--
		-- DONE im.api.nvim_set_hl(0, "DiagnosticSignWarn", { fg = "#e0af68", bg = "#1a1b26" })
		-- DONE im.api.nvim_set_hl(0, "DiagnosticSignInfo", { fg = "#0db9d7", bg = "#1a1b26" })
		-- DONE im.api.nvim_set_hl(0, "DiagnosticSignHint", { fg = "#1abc9c", bg = "#1a1b26" })
		-- DONE im.api.nvim_set_hl(0, "DiagnosticSignError", { fg = "#db4b4b", bg = "#1a1b26" })
		--
		-- vim.api.nvim_set_hl(0, "CodeBlock", { bg = "#222436" })
		-- -- vim.api.nvim_set_hl(0, 'Headline1', { fg = '#ff9e64', bg = '#965027' })
		--
		-- function Handle_Win_Enter()
		-- 	vim.cmd([[ setlocal winhighlight=Normal:ActiveWindow,NormalNC:InactiveWindow ]])
		-- end
		--
		-- local augr = vim.api.nvim_create_augroup -- Create/get autocommand group
		-- vim.api.nvim_create_autocmd({ "WinEnter" }, {
		-- 	pattern = "*",
		-- 	group = augr("WindowManagement", { clear = true }), --augr_handle
		-- 	callback = Handle_Win_Enter,
		-- })
	end,
	-- opts = {
	-- 	transparent = true, -- Enable this to disable setting the background color
	-- 	dim_inactive = true, -- dims inactive windows
	-- 	styles = {
	-- 		sidebars = "transparent",
	-- 		floats = "transparent",
	-- 	},
	-- },
}
