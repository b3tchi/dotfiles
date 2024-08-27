return {
	"robitx/gp.nvim",
	config = function()
		local home = os.getenv("HOME")
		require("gp").setup({
			openai_api_key = { "cat", home .. "/.config/open-ai/token" },
			agents = {
				{
					name = "ChatGPT4",
					chat = true,
					command = false,
					-- string with model name or table with model name and parameters
					model = { model = "gpt-4-1106-preview", temperature = 1.1, top_p = 1 },
					-- system prompt (use this to specify the persona/role of the AI)
					system_prompt = "You are a general AI assistant.\n\n"
						.. "The user provided the additional info about how they would like you to respond:\n\n"
						.. "- If you're unsure don't guess and say you don't know instead.\n"
						.. "- Ask question if you need clarification to provide better answer.\n"
						.. "- Think deeply and carefully from first principles step by step.\n"
						.. "- Zoom out first to see the big picture and then zoom in to details.\n"
						.. "- Use Socratic method to improve your thinking and coding skills.\n"
						.. "- Don't elide any code from your output if the answer requires coding.\n"
						.. "- Take a deep breath; You've got this!\n",
				},
				{
					name = "ChatGPT3-5",
					-- chat = true,
					-- command = false,
					-- -- string with model name or table with model name and parameters
					-- model = { model = "gpt-3.5-turbo-1106", temperature = 1.1, top_p = 1 },
					-- -- system prompt (use this to specify the persona/role of the AI)
					-- system_prompt = "You are a general AI assistant.\n\n"
					-- 	.. "The user provided the additional info about how they would like you to respond:\n\n"
					-- 	.. "- If you're unsure don't guess and say you don't know instead.\n"
					-- 	.. "- Ask question if you need clarification to provide better answer.\n"
					-- 	.. "- Think deeply and carefully from first principles step by step.\n"
					-- 	.. "- Zoom out first to see the big picture and then zoom in to details.\n"
					-- 	.. "- Use Socratic method to improve your thinking and coding skills.\n"
					-- 	.. "- Don't elide any code from your output if the answer requires coding.\n"
					-- 	.. "- Take a deep breath; You've got this!\n",
				},
				{
					name = "CodeGPT4",
					chat = false,
					command = true,
					-- string with model name or table with model name and parameters
					model = { model = "gpt-4-1106-preview", temperature = 0.8, top_p = 1 },
					-- system prompt (use this to specify the persona/role of the AI)
					system_prompt = "You are an AI working as a code editor.\n\n"
						.. "Please AVOID COMMENTARY OUTSIDE OF THE SNIPPET RESPONSE.\n"
						.. "START AND END YOUR ANSWER WITH:\n\n```",
				},
			},
			chat_user_prefix = "## User",
			chat_assistant_prefix = { "### ", "[{{agent}}]" },
		})

		-- or setup with your own config (see Install > Configuration in Readme)
		-- require("gp").setup(config)
		-- shortcuts might be setup here (see Usage > Shortcuts in Readme)
	end,
	keys = {
		-- disable the keymap to grep files
		-- {"<leader>/", false},
		-- change a keymap
		{ "<leader>ao", "<cmd>GpChatNew<cr>", desc = "new" },
		{ "<leader>aa", "<cmd>GpChatToggle<cr>", desc = "open" },
		{ "<leader>af", "<cmd>GpChatFinder<cr>", desc = "find" },
		{ "<leader>ar", "<cmd>GpChatRespond<cr>", desc = "respond" },
		-- add a keymap to browse plugin files
		-- {
		--   "<leader>fp",
		--   function() require("telescope.builtin").find_files({ cwd = require("lazy.core.config").options.root }) end,
		--   desc = "Find Plugin File",
		-- },
	},
}
