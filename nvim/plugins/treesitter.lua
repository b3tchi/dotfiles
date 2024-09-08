return {
	"nvim-treesitter/nvim-treesitter",
	opts = {
		ensure_installed = {
			"bash",
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
		},
	},
	config = function()
		local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
		parser_config.powershell = {
			install_info = {
				url = "https://github.com/airbus-cert/tree-sitter-powershell",
				files = { "src/parser.c", "src/scanner.c" },
				branch = "main",
			},
			filetype = "ps1",
		}
		-- parser_config.nu = {
		-- 	install_info = {
		-- 		url = "https://github.com/nushell/tree-sitter-nu",
		-- 		files = { "src/parser.c" },
		-- 		branch = "main",
		-- 	},
		-- 	filetype = "nu",
		-- }
	end,
	dependencies = {
		-- NOTE: additional parser
		{ "nushell/tree-sitter-nu" },
	},
	build = ":TSUpdate",
}
