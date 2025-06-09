return {
	"nvim-neo-tree/neo-tree.nvim",
	branch = "v3.x",
	dependencies = {
		"nvim-lua/plenary.nvim",
		"nvim-tree/nvim-web-devicons", -- not strictly required, but recommended
		"MunifTanjim/nui.nvim",
		"s1n7ax/nvim-window-picker",
		-- "3rd/image.nvim", -- Optional image support in preview window: See `# Preview Mode` for more information
		{
			"s1n7ax/nvim-window-picker",
			version = "2.*",
			name = "window-picker",
			event = "VeryLazy",
			config = function()
				local window_picker = require("window-picker")

				window_picker.setup({
					-- hint = "statusline-winbar",
					hint = "floating-big-letter",
					show_prompt = false,
					filter_func = function(window_ids, filters)
						local function predicate(wid)
							local cfg = vim.api.nvim_win_get_config(wid)
							if not cfg.focusable then
								return false
							end
							return true
						end
						local filtered = vim.tbl_filter(predicate, window_ids)

						local dfilter = require("window-picker.filters.default-window-filter"):new()
						dfilter:set_config(filters)
						return dfilter:filter_windows(filtered)
					end,
				})

				vim.keymap.set("n", "<leader><CR>", function()
					local choice = window_picker.pick_window() or vim.api.nvim_get_current_win()
					vim.api.nvim_set_current_win(choice)
				end, { desc = "Jump to window" })
			end,
		},
	},
	cmd = "Neotree",
	keys = {
		{
			"<leader>fe",
			function()
				require("neo-tree.command").execute({ toggle = true, dir = require("lazyvim.util").get_root() })
			end,
			desc = "Explorer NeoTree (root dir)",
		},
		{
			"<leader>fE",
			function()
				require("neo-tree.command").execute({ toggle = true, dir = vim.loop.cwd() })
			end,
			desc = "Explorer NeoTree (cwd)",
		},
		{ "<leader>e", "<leader>fe", desc = "Explorer NeoTree (root dir)", remap = true },
		{ "<leader>E", "<leader>fE", desc = "Explorer NeoTree (cwd)", remap = true },
	},
	deactivate = function()
		vim.cmd([[Neotree close]])
	end,
	init = function()
		vim.g.neo_tree_remove_legacy_commands = 1
		if vim.fn.argc() == 1 then
			local stat = vim.loop.fs_stat(vim.fn.argv(0))
			if stat and stat.type == "directory" then
				require("neo-tree")
			end
		end
	end,
	opts = {
		sources = { "filesystem", "buffers", "git_status", "document_symbols" },
		open_files_do_not_replace_types = { "terminal", "Trouble", "qf", "Outline" },
		filesystem = {
			bind_to_cwd = false,
			follow_current_file = {
				enabled = true,
			},
			use_libuv_file_watcher = true,
		},
		window = {
			mappings = {
				["<space>"] = {
					"toggle_node",
					nowait = false, -- disable `nowait` if you have existing combos starting with this char that you want to use
				},
				["b"] = "split_with_window_picker",
				["s"] = "vsplit_with_window_picker",
				["t"] = "open_tabnew",
				["l"] = "open_with_window_picker",
				["h"] = "close_node",
				["z"] = "close_all_nodes",
				["Z"] = "expand_all_nodes",
				["a"] = {
					"add",
					-- some commands may take optional config options, see `:h neo-tree-mappings` for details
					config = {
						show_path = "none", -- "none", "relative", "absolute"
					},
				},
				["<cr>"] = "set_root",
				["."] = "toggle_hidden",
				["A"] = "add_directory", -- also accepts the optional config.show_path option like "add".
				["d"] = "delete",
				["r"] = "rename",
				["y"] = "copy_to_clipboard",
				["x"] = "cut_to_clipboard",
				["p"] = "paste_from_clipboard",
				["c"] = "copy", -- takes text input for destination, also accepts the optional config.show_path option like "add":
				["m"] = "move", -- takes text input for destination, also accepts the optional config.show_path option like "add".
				["q"] = "close_window",
				["R"] = "refresh",
				["?"] = "show_help",
			},
		},
		default_component_configs = {
			indent = {
				with_expanders = true, -- if nil and file nesting is enabled, will enable expanders
				expander_collapsed = "+",
				expander_expanded = "-",
				-- expander_collapsed = "",
				-- expander_expanded = "",
				expander_highlight = "NeoTreeExpander",
			},
		},
	},
	config = function(_, opts)
		require("neo-tree").setup(opts)
		vim.api.nvim_create_autocmd("TermClose", {
			pattern = "*lazygit",
			callback = function()
				if package.loaded["neo-tree.sources.git_status"] then
					require("neo-tree.sources.git_status").refresh()
				end
			end,
		})
	end,
}
