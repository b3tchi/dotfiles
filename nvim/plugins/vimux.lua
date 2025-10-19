return {
	--Tmux Navigator
	{
		"christoomey/vim-tmux-navigator",
		keys = {
			{ "<C-h>", "<cmd>TmuxNavigateLeft<cr>", silent = true, remap = false, desc = "" },
			{ "<C-j>", "<cmd>TmuxNavigateDown<cr>", silent = true, remap = false, desc = "" },
			{ "<C-k>", "<cmd>TmuxNavigateUp<cr>", silent = true, remap = false, desc = "" },
			{ "<C-l>", "<cmd>TmuxNavigateRight<cr>", silent = true, remap = false, desc = "" },
		},
	},

  --{ "e", "<cmd><CR>", { silent = true, desc = "float variables" } },

	--vimux commands
	{
		"preservim/vimux",
		keys = {
			-- { "<leader>mo", "<cmd>VimuxOpenRunner<cr>", silent = true, remap = false, desc = "open" },
			{ "<leader>mo", "<cmd>lua require('wzor').spawnMultiplexerWindow('local')<CR>", silent = true, remap = false, desc = "open" },
			{ "<leader>mO", "<cmd>lua require('wzor').spawnMultiplexerWindow('WSL:Ubuntu-20.04')<CR>", silent = true, remap = false, desc = "open" },
			{ "<leader>ms", "<cmd>lua require('wzor').startTmuxSession()<CR>", silent = true, remap = false, desc = "start tmux session" },
			{ "<leader>mq", "<cmd>lua require('wzor').killMultiplexerWindow()<CR>", silent = true, remap = false, desc = "close" },
			-- { "<leader>ml", "<cmd>VimuxRunLastCommand<cr>", silent = true, remap = false, desc = "last command" },
			-- { "<leader>mx", "<cmd>VimuxInteruptRunner<cr>", silent = true, remap = false, desc = "interupt" },
			-- { "<leader>mi", "<cmd>VimuxInspectRunner<CR>", silent = true, remap = false, desc = "inspect" },
			-- { "<leader>mp", "<cmd>VimuxPromptCommand<CR>", silent = true, remap = false, desc = "prompt" },
			-- {
			-- 	"<leader>mc",
			-- 	'<cmd>VimuxRunCommand getline(".")<CR>',
			-- 	silent = true,
			-- 	remap = false,
			-- 	desc = "inner command",
			-- },
			{ "<leader>mc", "<cmd>lua require('wzor').sendLineToMultiplexerWindow()<CR>", silent = true, remap = false, desc = "send line" },
			{ "<leader>mq", "<cmd>lua require('wzor').killMultiplexerWindow()<CR>", silent = true, remap = false, desc = "close" },
			{ "<leader>mb", "<cmd>lua require('wzor').sendBlockToMultiplexerWindow()<CR>", silent = true, remap = false, desc = "send block" },
			-- { "<leader>mb", ":lua vimux_md_block()<CR>", silent = false, remap = false, desc = "block run" },
		},
		init = function()
			vim.g.VimuxRunnerType = "window"

			function _G.vimux_md_block()
				local mdblock = {}

				local function mdblock_bash(code_block, mdpath)
					--prepare bash
					local block_header = {
						"#!/bin/bash",
						"#get notes root",
						"NOTES_ROOT='" .. mdpath .. "/'",
						'if [[ -f "${NOTES_ROOT}.env" ]]; then',
						'     source "${NOTES_ROOT}.env"',
						"fi",
						"#look for active branch in tmux",
						'ATTACHED_BRANCH="$(tools mpxr attached-branch-path --project-root-path "$PROJECT_ROOT")"',
						"#try to find environment variables",
						"if [[ ! -z ${ATTACHED_BRANCH} ]]; then",
						"     if [[ ! -z ${YAML_VARS} ]]; then",
						'          eval "$(tools ad pipe var load-to-env --vars-yaml "$PROJECT_ROOT$ATTACHED_BRANCH$YAML_VARS")"',
						"    fi",
						"fi",
						"#----END of automatic header----",
					}
					local temp_path = vim.g.lux_temppath() .. vim.g.tmp_file("sh")

					vim.fn.writefile(block_header, temp_path)
					vim.fn.writefile(code_block, temp_path, "a")

					local cmd = "bash '" .. temp_path .. "'"

					vim.fn.VimuxRunCommand(cmd)
				end

				if vim.bo.filetype == "markdown" then
					mdblock = md_block_get()
				elseif vim.bo.filetype == "org" then
					mdblock = org_block_get()
				else
					print("not covered format only .org or .md")
					return
				end

				-- "bash command
				if mdblock.lang == "bash" then
					-- if type(mdblock_bash) == "function" then
					mdblock_bash(mdblock.code, mdblock.path)
					-- else
					-- print("not exists")
					-- end

					-- "powershell
					-- elseif mdblock.lang == "powershell" then
					-- 	if type(mdblock_powershell) == "function" then
					-- 		mdblock_powershell(mdblock.code)
					-- 	else
					-- 		print("not exists")
					-- 	end
					-- elseif mdblock.lang == "cs" or mdblock.lang == "csharp" then
					-- 	if type(mdblock_csharp) == "function" then
					-- 		mdblock_csharp(mdblock.code)
					-- 	else
					-- 		print("not exists")
					-- 	end
					-- elseif mdblock.lang == "pwsh" then
					-- 	if type(mdblock_pwsh) == "function" then
					-- 		mdblock_pwsh(mdblock.code)
					-- 	else
					-- 		print("not exists")
					-- 	end
					-- elseif mdblock.lang == "vim" then
					-- 	if type(mdblock_vim) == "function" then
					-- 		mdblock_vim(mdblock.code)
					-- 	else
					-- 		print("not exists")
					-- 	end
					-- elseif mdblock.lang == "lua" then
					-- 	if type(mdblock_lua) == "function" then
					-- 		mdblock_lua(mdblock.code)
					-- 	else
					-- 		print("not exists")
					-- 	end
				else
					print("not know code format")
				end
			end

			vim.g.vimux_md_block = _G.vimux_md_block

			function _G.tmp_file(extension)
				local fname = os.date("%Y%m%d_%H%M%S") .. "." .. extension

				return fname
			end
			vim.g.tmp_file = _G.tmp_file

			function _G.winpath_from_wsl(winpath)
				local unx_tmpps = vim.fn.substitute(winpath, "\\", "/", "g")
				local unx_tmpps = vim.fn.substitute(unx_tmpps, "C:", "/mnt/c", "g")

				return unx_tmpps
			end
			vim.g.winpath_from_wsl = _G.winpath_from_wsl

			function _G.lux_temppath()
				local temppath = "/tmp/nvim_mdblocks/"

				vim.fn.mkdir(temppath, "p")
				return temppath
			end
			vim.g.lux_temppath = _G.lux_temppath

			function _G.win_temppath()
				local win_tmpps = vim.fn.trim(vim.fn.system("cd /mnt/c/ && cmd.exe /c echo %TEMP% && cd - | grep C: "))
					.. "\\nvim_mdblocks\\"

				--create temp folder if not exists
				vim.fn.mkdir(winpath_from_wsl(win_tmpps), "p")

				return win_tmpps
			end
			vim.g.win_temppath = _G.win_temppath

			function md_block_get()
				local block_line_begin = vim.fn.search("^```[a-z0-9]*$", "bnW")
				local block_line_end = vim.fn.search("^```$", "nW")

				local resp = {}

				resp.lang = vim.fn.getline(block_line_begin):sub(4)
				resp.code = vim.fn.getline(block_line_begin + 1, block_line_end - 1)
				resp.path = vim.fn.expand("%:p:h")

				return resp
			end

			function org_block_get()
				local block_line_begin = vim.fn.search("#+begin_src [a-z0-9]*$", "bnW")
				local block_line_end = vim.fn.search("#+end_src$", "nW")

				local resp = {}

				resp.lang = vim.fn.matchlist(vim.fn.getline(block_line_begin), "\\(#+begin_src \\)\\(.*\\)\\?")[3]
				resp.code = vim.fn.getline(block_line_begin + 1, block_line_end - 1)
				resp.path = vim.fn.expand("%:p:h")

				return resp
			end
		end,
	},
}
