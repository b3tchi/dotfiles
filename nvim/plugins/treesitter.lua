return {
	"nvim-treesitter/nvim-treesitter",
	-- d2 isn't in nvim-treesitter's main-branch registry. The ravsii/tree-sitter-d2
	-- grammar registers it, but only inside a `User TSUpdate` autocmd that loads
	-- AFTER nvim-treesitter (it depends on it) — so `ensure_installed` runs first
	-- and warns "skipping unsupported language: d2". Registering here in `init`
	-- (before nvim-treesitter's setup fires `User TSUpdate`) makes d2 known in time.
	init = function()
		vim.api.nvim_create_autocmd("User", {
			pattern = "TSUpdate",
			callback = function()
				require("nvim-treesitter.parsers").d2 = {
					install_info = { path = vim.fn.stdpath("data") .. "/lazy/tree-sitter-d2" },
				}
			end,
		})
	end,
	opts = {
		ensure_installed = {
			"bash",
			"d2",
			"html",
			"javascript",
			"json",
			"lua",
			"markdown",
			"markdown_inline",
			"python",
			"query",
			"regex",
			"tsx",
			"typescript",
			"vim",
			"yaml",
			"nu",
			"rasi",
		},
		-- highlight = {
		-- 	enable = true,
		-- 	additional_vim_regex_highlighting = { "org" },
		-- },
		ignore_install = { "org" },
		playground = {
			enable = true,
			updatetime = 25, -- Debounced time for highlighting nodes in the playground from source code
			persist_queries = false, -- Whether the query persists across vim sessions
		},
	},
	--
	-- TSUpdate
	-- config = function()
	-- 	local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
	-- 	parser_config.powershell = {
	-- 		install_info = {
	-- 			url = "https://github.com/airbus-cert/tree-sitter-powershell",
	-- 			files = { "src/parser.c", "src/scanner.c" },
	-- 			branch = "main",
	-- 		},
	-- 		filetype = "ps1",
	-- 	}
	-- 	-- parser_config.nu = {
	-- 	-- 	install_info = {
	-- 	-- 		url = "https://github.com/nushell/tree-sitter-nu",
	-- 	-- 		files = { "src/parser.c" },
	-- 	-- 		branch = "main",
	-- 	-- 	},
	-- 	-- 	filetype = "nu",
	-- 	-- }
	-- end,
	-- TSUpdate
	--
	-- dependencies = {
	-- 	-- NOTE: additional parser
	-- 	{ "nushell/tree-sitter-nu" },
	-- },
	build = ":TSUpdate",
}
