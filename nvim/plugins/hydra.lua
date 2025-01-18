return {
	"anuvyklack/hydra.nvim",
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
