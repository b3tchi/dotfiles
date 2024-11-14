return {
	-- { "nanotee/sqls.nvim" },
	{
		"neovim/nvim-lspconfig",
		-- ---@class PluginLspOpts
		opts = {
			-- ---@type lspconfig.options
			servers = {
				-- pyright will be automatically installed with mason and loaded with lspconfig
				lua_ls = {
					settings = {
						Lua = {
							runtime = {
								-- Tell the language server which version of Lua you're using
								-- (most likely LuaJIT in the case of Neovim)
								version = "LuaJIT",
							},
							diagnostics = {
								-- Get the language server to recognize the `vim` global
								globals = {
									"vim",
									"require",
								},
							},
							workspace = {
								-- Make the server aware of Neovim runtime files
								library = vim.api.nvim_get_runtime_file("", true),
							},
							-- Do not send telemetry data containing a randomized but unique identifier
							telemetry = {
								enable = false,
							},
						},
					},
				},
				--getting working sql-ls for mssql seem there are still some issues only workis when loaded via :source file.lua
				----- file content -----
				-- sqls = {
				-- 	default_config = {
				-- 		cmd = { "sqls" },
				-- 		filetypes = { "sql" },
				-- 		root_dir = function(fname) end,
				-- 	},
				-- 	connections = {
				-- 		{
				-- 			driver = "mssql",
				-- 			dataSourceName = "sqlserver://sa:4dm1n1-str4t0r@localhost:1433?database=hr_db&encrypt=true&trustServerCertificate=true",
				-- 		},
				-- 	},
				-- },
				----- file content -----
				-- using lazy offical extra lang.nushell
				-- nushell = {
				-- 	default_config = {
				-- 		cmd = { "nu", "--lsp" },
				-- 		filetypes = { "nu" },
				-- 		root_dir = function(fname) end,
				-- 	},
				-- },
			},
		},
	},
}
