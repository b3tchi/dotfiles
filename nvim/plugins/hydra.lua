return {
	"nvimtools/hydra.nvim",
	dependencies = {
		"mrjones2014/smart-splits.nvim",
		"sindrets/winshift.nvim",
		"mfussenegger/nvim-dap",
		"anuvyklack/windows.nvim",
		"anuvyklack/middleclass",
	},
	config = function()
		local hydra = require("hydra")
		local splits = require("smart-splits")
		local cmd = require("hydra.keymap-util").cmd
		local pcmd = require("hydra.keymap-util").pcmd

		require("windows").setup()

		-- local buffer_hydra = Hydra({
		--    name = 'Barbar',
		--    config = {
		--       on_key = function()
		--          -- Preserve animation
		--          vim.wait(200, function() vim.cmd 'redraw' end, 30, false)
		--       end
		--    },
		--    heads = {
		--       { 'h', function() vim.cmd('BufferPrevious') end, { on_key = false } },
		--       { 'l', function() vim.cmd('BufferNext') end, { desc = 'choose', on_key = false } },
		--
		--       { 'H', function() vim.cmd('BufferMovePrevious') end },
		--       { 'L', function() vim.cmd('BufferMoveNext') end, { desc = 'move' } },
		--
		--       { 'p', function() vim.cmd('BufferPin') end, { desc = 'pin' } },
		--
		--       { 'd', function() vim.cmd('BufferClose') end, { desc = 'close' } },
		--       { 'c', function() vim.cmd('BufferClose') end, { desc = false } },
		--       { 'q', function() vim.cmd('BufferClose') end, { desc = false } },
		--
		--       { 'od', function() vim.cmd('BufferOrderByDirectory') end, { desc = 'by directory' } },
		--       { 'ol', function() vim.cmd('BufferOrderByLanguage') end,  { desc = 'by language' } },
		--       { '<Esc>', nil, { exit = true } }
		--    }
		-- })
		--
		-- local function choose_buffer()
		-- 	if #vim.fn.getbufinfo({ buflisted = true }) > 1 then
		-- 		buffer_hydra:activate()
		-- 	end
		-- end
		--
		-- vim.keymap.set("n", "gb", choose_buffer)
		-- call tablemode#spreadsheet#cell#Motion('j')

		-- local Hydra = require("hydra")

		hydra({
			name = "TableMode",
			config = {
				color = "pink",
				invoke_on_body = true,
				hint = {
					type = "window",
				},
			},
			mode = "n",
			body = "<leader>t,",
			heads = {
				{ "h", cmd("call tablemode#spreadsheet#cell#Motion('h')") },
				{ "l", cmd("call tablemde#spreadsheet#cell#Motion('l')") },
				{ "s", cmd("TableSort!") },
				{ "S", cmd("TableSort") },
				{ "?", cmd("call tablemode#spreadsheet#EchoCell()") },
				{ "c", cmd("call tablemode#spreadsheet#InsertColumn(0)"), { exit = true, desc = "add col after" } },
				{ "C", cmd("call tablemode#spreadsheet#InsertColumn(1)"), { exit = true, desc = "add cal before" } },
				{ "d", cmd("call tablemode#spreadsheet#DeleteColumn()") },
				{ "r", cmd("call tablemode#table#Realign('.')") },
				{ "f", cmd("call tablemode#spreadsheet#formula#Add()"), { exit = true, desc = "add formula" } },
				{ "e", cmd("call tablemode#spreadsheet#formula#EvaluateFormulaLine()") },
				{ "<Esc>", nil, { exit = true, mode = "n" } },
			},
		})

		local window_hint = "Move _H__J__K__L_ Size _h__j__k__l_ _=_ Split _b__s_ Max _z_ Close _q__c_ Only _o_"

		hydra({
			name = "Windows",
			hint = window_hint,
			config = {
				invoke_on_body = true,
			},
			mode = "n",
			body = "<C-w>",
			heads = {
				{ "<C-h>", "<C-w>h", { desc = false } },
				{ "<C-j>", "<C-w>j", { desc = false } },
				{ "<C-k>", pcmd("wincmd k", "E11", "close"), { desc = false } },
				{ "<C-l>", "<C-w>l", { desc = false } },

				{ "H", cmd("WinShift left") },
				{ "J", cmd("WinShift down") },
				{ "K", cmd("WinShift up") },
				{ "L", cmd("WinShift right") },

				{
					"h",
					function()
						splits.resize_left(2)
					end,
				},
				{
					"j",
					function()
						splits.resize_down(2)
					end,
				},
				{
					"k",
					function()
						splits.resize_up(2)
					end,
				},
				{
					"l",
					function()
						splits.resize_right(2)
					end,
				},

				{ "=", "<C-w>=", { desc = "equalize" } },

				{ "b", pcmd("split", "E36") },
				{ "<C-b>", pcmd("split", "E36"), { desc = false } },
				{ "s", pcmd("vsplit", "E36") },
				{ "<C-s>", pcmd("vsplit", "E36"), { desc = false } },

				{ "w", "<C-w>w", { exit = true, desc = false } },
				{ "<C-w>", "<C-w>w", { exit = true, desc = false } },

				{ "z", cmd("WindowsMaximize"), { exit = true, desc = "maximize" } },
				{ "<C-z>", cmd("WindowsMaximize"), { exit = true, desc = false } },

				{ "o", "<C-w>o", { exit = true, desc = "remain only" } },
				{ "<C-o>", "<C-w>o", { exit = true, desc = false } },

				-- { "b", choose_buffer, { exit = true, desc = "choose buffer" } },

				{ "c", pcmd("close", "E444") },
				{ "<C-c>", pcmd("close", "E444"), { desc = false } },
				{ "q", pcmd("close", "E444"), { desc = "close window" } },
				{ "<C-q>", pcmd("close", "E444"), { desc = false } },

				{ "<Esc>", nil, { exit = true, desc = false } },
			},
		})

		local dap = require("dap")

		local hint = "Step over/in/out _J__L__H_ Continue _c_ Terminate _x_ Quit _q_"
		hydra({
			name = "Debug",
			hint = hint,
			config = {
				color = "pink",
				invoke_on_body = true,
				hint = {
					type = "window",
				},
			},
			mode = { "n" },
			body = "<leader>d,",
			heads = {
				{ "H", dap.step_out, { desc = "step out" } },
				{ "J", dap.step_over, { desc = "step over" } },
				-- { "K", dap.step_back, { desc = "step back" } },
				{ "L", dap.step_into, { desc = "step into" } },
				-- { "t", dap.toggle_breakpoint, { desc = "toggle breakpoint" } },
				-- { "T", dap.clear_breakpoints, { desc = "clear breakpoints" } },
				{ "c", dap.continue, { desc = "continue" } },
				{ "x", dap.terminate, { desc = "terminate" } },
				-- { "r", dap.repl.open, { exit = true, desc = "open repl" } },
				{ "q", nil, { exit = true, nowait = true, desc = "exit" } },
			},
		})

		-- Helper function to preview fold in split pane
		local function preview_fold_in_split()
			local ufo = require("ufo")
			local bufnr = vim.api.nvim_get_current_buf()
			local lnum = vim.fn.line(".")

			-- Get fold range
			local fold_start = vim.fn.foldclosed(lnum)
			if fold_start == -1 then
				vim.notify("No fold under cursor", vim.log.levels.WARN)
				return
			end

			local fold_end = vim.fn.foldclosedend(lnum)

			-- Create or reuse preview split
			if not vim.g.ufo_split_preview_winid or not vim.api.nvim_win_is_valid(vim.g.ufo_split_preview_winid) then
				-- Create split below current window
				vim.cmd("below split")
				vim.g.ufo_split_preview_winid = vim.api.nvim_get_current_win()
				vim.g.ufo_split_preview_bufnr = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_win_set_buf(vim.g.ufo_split_preview_winid, vim.g.ufo_split_preview_bufnr)
				-- Set height to 50% of screen
				local screen_height = vim.o.lines
				vim.api.nvim_win_set_height(vim.g.ufo_split_preview_winid, math.floor(screen_height * 0.5))
				vim.bo[vim.g.ufo_split_preview_bufnr].bufhidden = "wipe"
				vim.bo[vim.g.ufo_split_preview_bufnr].buftype = "nofile"
				vim.wo[vim.g.ufo_split_preview_winid].wrap = false
				vim.wo[vim.g.ufo_split_preview_winid].number = true
				vim.wo[vim.g.ufo_split_preview_winid].relativenumber = false
				-- Go back to original window
				vim.cmd("wincmd p")
			end

			-- Get fold content
			local lines = vim.api.nvim_buf_get_lines(bufnr, fold_start - 1, fold_end, false)

			-- Update preview buffer
			vim.api.nvim_buf_set_lines(vim.g.ufo_split_preview_bufnr, 0, -1, false, lines)
			vim.api.nvim_buf_set_option(vim.g.ufo_split_preview_bufnr, "filetype", vim.bo[bufnr].filetype)
			vim.api.nvim_buf_set_name(vim.g.ufo_split_preview_bufnr, "Fold Preview (lines " .. fold_start .. "-" .. fold_end .. ")")
		end

		hydra({
			name = "Fold",
			hint = "_z_toggle _o_pen _c_lose | All: _O_ open _C_ close | Level: _m_ dec _r_ inc | Nav: _j_ next _k_ prev | _p_eek _P_ pane _q_uit",
			config = {
				color = "pink",
				invoke_on_body = true,
				hint = {
					type = "window",
				},
				on_exit = function()
					-- Clean up preview pane when exiting hydra
					if vim.g.ufo_split_preview_winid and vim.api.nvim_win_is_valid(vim.g.ufo_split_preview_winid) then
						vim.api.nvim_win_close(vim.g.ufo_split_preview_winid, true)
						vim.g.ufo_split_preview_winid = nil
						vim.g.ufo_split_preview_bufnr = nil
					end
					vim.g.ufo_preview_persistent = false
				end,
			},
			mode = "n",
			body = "zM",
			heads = {
				-- Basic operations
				{ "z", "za", { desc = "toggle fold" } },
				{ "o", "zo", { desc = "open fold" } },
				{ "c", "zc", { desc = "close fold" } },

				-- All folds
				{ "O", function()
					require("ufo").openAllFolds()
				end, { desc = "open all folds" } },
				{ "C", function()
					require("ufo").closeAllFolds()
				end, { desc = "close all folds" } },

				-- Foldlevel adjustment
				{ "m", "zm", { desc = "decrease foldlevel" } },
				{ "r", "zr", { desc = "increase foldlevel" } },

				-- Navigation
				{ "j", function()
					vim.cmd("normal! zj")
					if vim.g.ufo_preview_persistent then
						preview_fold_in_split()
					end
				end, { desc = "next fold" } },
				{ "k", function()
					vim.cmd("normal! zk")
					if vim.g.ufo_preview_persistent then
						preview_fold_in_split()
					end
				end, { desc = "previous fold" } },

				-- UFO-specific: Peek folded lines
				{ "p", function()
					preview_fold_in_split()
				end, { desc = "peek folded lines" } },

				-- Persistent preview in split pane
				{ "P", function()
					-- Toggle persistent preview mode
					if vim.g.ufo_preview_persistent then
						vim.g.ufo_preview_persistent = false
						if vim.g.ufo_split_preview_winid and vim.api.nvim_win_is_valid(vim.g.ufo_split_preview_winid) then
							vim.api.nvim_win_close(vim.g.ufo_split_preview_winid, true)
							vim.g.ufo_split_preview_winid = nil
							vim.g.ufo_split_preview_bufnr = nil
						end
					else
						vim.g.ufo_preview_persistent = true
						preview_fold_in_split()
					end
				end, { desc = "toggle persistent preview" } },

				-- Exit
				{ "q", nil, { exit = true, nowait = true, desc = "exit" } },
				{ "<Esc>", nil, { exit = true, desc = false } },
			},
		})

		-- vim.g.ps_terminal_jobid = 0
		--     local function llconsole(text)
		--       vim.fn.chansend(vim.g.ps_terminal_jobid ,text)
		--     end
		--
		--      hydra({
		--     name = "DebugPwshHack",
		--     hint = hint,
		--     config = {
		--       color = "pink",
		--       invoke_on_body = true,
		--       hint = {
		--         type = "window",
		--       },
		--     },
		--     mode = { "n" },
		--     body = "<leader>dh",
		--     heads = {
		--       -- { "H", dap.step_out, { desc = "step out" } },
		--       { "J", llconsole("v\r"), { desc = "step over" } },
		--       -- { "K", dap.step_back, { desc = "step back" } },
		--       -- { "L", dap.step_into, { desc = "step into" } },
		--       -- { "t", dap.toggle_breakpoint, { desc = "toggle breakpoint" } },
		--       -- { "T", dap.clear_breakpoints, { desc = "clear breakpoints" } },
		--       { "c", llconsole("c\r"), { desc = "continue" } },
		--       -- { "x", dap.terminate, { desc = "terminate" } },
		--       -- { "r", dap.repl.open, { exit = true, desc = "open repl" } },
		--       { "q", nil, { exit = true, nowait = true, desc = "exit" } },
		--     },
		--   })
		--
	end,
}
