local Path = require("plenary.path")
return {
	"b0o/incline.nvim",
	config = function()
		local function get_diagnostic_label(props)
			local icons = { error = "", warn = "", info = "", hint = "" }
			local label = {}

			for severity, icon in pairs(icons) do
				local n = #vim.diagnostic.get(props.buf, { severity = vim.diagnostic.severity[string.upper(severity)] })
				if n > 0 then
					table.insert(label, { icon .. " " .. n .. " ", group = "DiagnosticSign" .. severity })
				end
			end
			if #label > 0 then
				table.insert(label, { "| " })
			end
			return label
		end
		local function get_git_diff(props)
			local icons = { removed = "", changed = "", added = "" }
			local labels = {}
			-- local signs = vim.api.nvim_buf_get_var(props.buf, "gitsigns_status_dict")
			-- local signs = vim.b.gitsigns_status_dict
			local signs = vim.b[props.buf].gitsigns_status_dict
			if signs == nil then
				return labels
			end
			for name, icon in pairs(icons) do
				if tonumber(signs[name]) and signs[name] > 0 then
					table.insert(labels, { icon .. " " .. signs[name] .. " ", group = "Diff" .. name })
				end
			end
			if #labels > 0 then
				table.insert(labels, { "| " })
			end
			return labels
		end

		local function shorten_path(path, opts)
			opts = opts or {}
			local short_len = opts.short_len or 1
			local tail_count = opts.tail_count or 2
			local head_max = opts.head_max or 0
			local relative = opts.relative == nil or opts.relative
			local return_table = opts.return_table or false
			if relative then
				path = vim.fn.fnamemodify(path, ":.")
			end
			local components = vim.split(path, Path.path.sep)
			if #components == 1 then
				if return_table then
					return { nil, path }
				end
				return path
			end
			local tail = { unpack(components, #components - tail_count + 1) }
			local head = { unpack(components, 1, #components - tail_count) }
			if head_max > 0 and #head > head_max then
				head = { unpack(head, #head - head_max + 1) }
			end
			local result = {
				#head > 0 and Path.new(unpack(head)):shorten(short_len, {}) or nil,
				table.concat(tail, Path.path.sep),
			}
			if return_table then
				return result
			end
			return table.concat(result, Path.path.sep)
		end

		local function shorten_path_styled(path)
			local opts = {
				short_len = 1,
				tail_count = 2,
				head_max = 4,
				-- head_style = { group = "Comment" },
				-- tail_style = { guifg = "white" },
			}

			-- local head_style = opts.head_style or {}
			-- local tail_style = opts.tail_style or {}
			-- original issue to enable paths https://github.com/b0o/incline.nvim/issues/41
			local result = shorten_path(
				path,
				vim.tbl_extend("force", opts, {
					return_table = true,
				})
			)
			-- local file_path = {
			-- 	-- result[1] and vim.list_extend(head_style, { result[1], "/" }) or "",
			-- 	-- vim.list_extend(tail_style, { result[2] }),
			-- }
			-- local file_path = vim.list_extend(tail_style, { result[2] }) --result[2]
			local file_path = result[2]

			return file_path
		end

		require("incline").setup({
			render = function(props)
				-- local filename = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(props.buf), ":t")
				local filename = shorten_path_styled(vim.api.nvim_buf_get_name(props.buf))

				local ft_icon, ft_color = require("nvim-web-devicons").get_icon_color(filename)

				local modified_icon = vim.api.nvim_buf_get_option(props.buf, "modified") and " ● " or " "

				local buffer = {
					{ get_diagnostic_label(props) },
					{ get_git_diff(props) },
					{ ft_icon, guifg = ft_color },
					{ " " },
					-- { filename },
					{ filename },
					{ modified_icon },
				}
				return buffer
			end,
		})

		-- default settings
		-- require("incline").setup()
	end,
}
