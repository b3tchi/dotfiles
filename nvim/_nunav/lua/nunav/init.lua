local M = {}
-- Function to find function definitions using Tree-sitter
local function find_nushell_functions()
	local lang = "nu"
	local bufnr = vim.api.nvim_get_current_buf()
	local file_path = vim.api.nvim_buf_get_name(bufnr)
	local language_tree = vim.treesitter.get_parser(bufnr, lang)
	local syntax_tree = language_tree:parse()
	local root = syntax_tree[1]:root()
	local query_string = "(decl_def (cmd_identifier) @func_name)"
	local query = vim.treesitter.query.parse("nu", query_string)

	local results = {}

	for _, node, _ in query:iter_matches(root, bufnr) do
		local name = vim.treesitter.get_node_text(node[1], bufnr)
		-- local name = "dummy"
		local start_row, _, _, _ = node[1]:range()
		table.insert(results, {
			line = start_row + 1,
			text = name,
			path = file_path,
		})
	end

	return results
end

-- Function to set up and display the Telescope picker
M.telescope_nushell_functions = function()
	local opts = {}
	-- local function_results = { { line = 1, text = "bcx" }, { line = 5, text = "bcx" } }
	local function_results = find_nushell_functions()

	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local pickers = require("telescope.pickers")
	local previewers = require("telescope.previewers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values

	if vim.tbl_isempty(function_results) then
		print("No functions found")
		return
	end

	pickers
		.new(opts, {
			prompt_title = "Nushell Functions",
			finder = finders.new_table({
				results = function_results,
				entry_maker = function(entry)
					return {
						value = entry,
						display = entry.text,
						filename = entry.path,
						ordinal = entry.text,
						lnum = entry.line,
						col = 1,
					}
				end,
			}),
			sorter = conf.generic_sorter(opts),
			-- attach_mappings = function(prompt_bufnr, map)
			-- 	actions.select_default:replace(function()
			-- 		actions.close(prompt_bufnr)
			-- 		local selection = action_state.get_selected_entry()
			-- 		vim.api.nvim_win_set_cursor(0, { selection.value.line, 0 })
			-- 	end)
			-- 	return true
			-- end,
			previewer = conf.grep_previewer(opts),
		})
		:find()
end

-- Set up a keybinding to trigger the function
-- vim.api.nvim_set_keymap(
-- 	"n",
-- 	"<leader>nf",
-- 	':lua require("nunav").telescope_nushell_functions()<CR>',
-- 	{ noremap = true, silent = true }
-- )

return M
