-- add cmp-emoji
-- if true then return {} end
-- TBD
return {
	-- powershell.nvim requires 0.10 version
	{
		"TheLeoP/powershell.nvim",
		opts = {
			bundle_path = vim.fn.stdpath("data") .. "/mason/packages/powershell-editor-services",
		},
	},
	--==WORKING==--
	-- {
	-- 	"mfussenegger/nvim-dap",
	-- 	event = "VeryLazy",
	-- 	config = function()
	--      local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
	--
	--      parser_config.powershell = {
	--        install_info = {
	--          url = "https://github.com/airbus-cert/tree-sitter-powershell",
	--          files = { "src/parser.c", 'src/scanner.c' },
	--          branch = "main",
	--        },
	--        filetype = "ps1",
	--      }
	--
	-- 		local dap = require("dap")
	--
	-- 		-- WINDOWS PATHS
	-- 		local PSES_BUNDLE_PATH = "C:/Users/czjabeck/AppData/Local/nvim-data/mason/packages/powershell-editor-services"
	-- 		local session_path = "C:/Users/czjabeck/AppData/Local/Temp/nvim"
	--
	-- 		local PSES_BUNDLE_PATH = vim.fn.expand("~/.local/share/nvim/mason/packages/powershell-editor-services")
	-- 		local session_path = os.tmpname()
	--
	-- 		dap.adapters.ps1 = {
	-- 			type = "pipe",
	-- 			pipe = "//./pipe/test-pipe-123",
	-- 		}
	--
	-- 		dap.configurations.ps1 = {
	-- 			{
	-- 				name = "Attach to PowerShell Process",
	-- 				type = "ps1",
	-- 				request = "launch",
	--          script = "${file}",
	-- 			},
	-- 		}
	-- 	end,
	-- },

	--==TESTING==--
	-- {
	-- 	"mfussenegger/nvim-dap",
	-- 	event = "VeryLazy",
	-- 	config = function()
	--      local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
	--
	--      parser_config.powershell = {
	--        install_info = {
	--          url = "https://github.com/airbus-cert/tree-sitter-powershell",
	--          files = { "src/parser.c", 'src/scanner.c' },
	--          branch = "main",
	--        },
	--        filetype = "ps1",
	--      }
	--
	-- 		local dap = require("dap")
	--
	-- 		-- WINDOWS PATHS
	-- 		local PSES_BUNDLE_PATH = "C:/Users/czjabeck/AppData/Local/nvim-data/mason/packages/powershell-edior-services"
	-- 		local session_path = "C:/Users/czjabeck/AppData/Local/Temp/nvim"
	--
	-- 		-- local PSES_BUNDLE_PATH = vim.fn.expand("~/.local/share/nvim/mason/packages/powershell-editor-services")
	-- 		-- local session_path = os.tmpname()
	--
	-- 		-- os.execute("mkdir " .. session_path)
	-- 		dap.adapters.powershell = {
	-- 			type = "pipe",
	-- 			pipe = "//./pipe/test-pipe-123",
	-- 			-- pipe = "${pipe}",
	--  		executable = {
	--  			command = "pwsh",
	--  			args = {
	--  				"-NoLogo",
	--  				"-NoProfile",
	--  				-- "-NonInteractive",
	--  				"-OutputFormat",
	--  				"Text",
	--  				"-File",
	--  				PSES_BUNDLE_PATH .. "/PowerShellEditorServices/Start-EditorServices.ps1",
	--  				"-BundledModulesPath",
	--  				PSES_BUNDLE_PATH,
	--  				"-LogPath",
	--  				session_path .. "/logs.log",
	--  				"-SessionDetailsPath",
	--  				session_path .. "/session.json",
	--  "-EnableConsoleRepl",
	--  				"-HostName",
	--  				"Neovim",
	--  				"-HostProfileId",
	--  				"Neovim.DAP",
	--  				"-HostVersion",
	--  				"1.0.0",
	--  				"-LogLevel",
	--  				"Verbose",
	--  				"-DebugServiceOnly",
	--  				"-DebugServicePipeName",
	--  				"test-pipe-123",
	--  				-- "${pipe}",
	--  			},
	--  		},
	-- 		}
	-- --
	-- 		dap.configurations.ps1 = {
	-- 			{
	-- 				name = "Attach to PowerShell Process",
	-- 				type = "powershell",
	-- 				request = "launch",
	--          script = "${file}",
	-- 			},
	-- 		}
	-- 	end,
	-- },
}