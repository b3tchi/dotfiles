return {
	"folke/tokyonight.nvim",
	lazy = false,
	priority = 1000,
	config = function()
		require("tokyonight").setup({
			-- your configuration comes here
			-- or leave it empty to use the default settings
			-- style = "storm", -- The theme comes in three styles, `storm`, `moon`, a darker variant `night` and `day`
			style = "storm", -- The theme comes in three styles, `storm`, `moon`, a darker variant `night` and `day`
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
				sidebars = "dark", -- style for sidebars, see below
				floats = "dark", -- style for floating windows
			},

			sidebars = { "qf", "help" }, -- Set a darker background on sidebar-like windows. For example: `["qf", "vista_kind", "terminal", "packer"]`
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
				hl.Normal = { fg = "#7aa2f7" }
				hl.NeoTreeNormal = { fg = "#7aa2f7" }

				--column line with numbers
				local lineNr = "#1a1b26"
				hl.CursorLineNr = { fg = "#ff9e64", bg = lineNr }
				hl.LineNr = { fg = "#3b4261", bg = lineNr }
				hl.SignColumnSB = { bg = lineNr }
				hl.SignColumn = { bg = lineNr }
				hl.UfoCursorFoldedLine = { fg = "#3b4261", bg = lineNr }
				hl.CursorLineFold = { fg = "#3b4261", bg = lineNr }
				hl.FoldColumn = { fg = "#3b4261", bg = lineNr }

				hl.GitSignsAdd = { fg = "#266d6a", bg = lineNr }
				hl.GitSignsChange = { fg = "#536c9e", bg = lineNr }
				hl.GitSignsDelete = { fg = "#b2555b", bg = lineNr }

				hl.DiagnosticSignWarn = { fg = "#e0af68", bg = lineNr }
				hl.DiagnosticSignInfo = { fg = "#0db9d7", bg = lineNr }
				hl.DiagnosticSignHint = { fg = "#1abc9c", bg = lineNr }
				hl.DiagnosticSignError = { fg = "#db4b4b", bg = lineNr }

				--separator between panes same as LineNr
				hl.WinSeparator = { fg = lineNr, bg = lineNr }

				--foldes
				hl.Folded = { bg = "#222436" } --fold-ufo
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
