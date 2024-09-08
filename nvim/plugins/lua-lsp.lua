return {
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
			-- using lazy offical extra lang.nushell
			nushell = {
				default_config = {
					cmd = { "nu", "--lsp" },
					filetypes = { "nu" },
					root_dir = function(fname) end,
				},
			},
		},
	},
}
