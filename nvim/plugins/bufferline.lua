return {
	"akinsho/bufferline.nvim",
	config = {
		options = {

			sort_by = function(a, b)
				local function get_buffer_time(bufnr)
					--
					-- Check if last_focused_time is available
					local focused_time = vim.b[bufnr] and vim.b[bufnr].last_focused_time
					if focused_time then
						return focused_time
					else
						return bufnr
					end
				end

				local time_a = get_buffer_time(a.id)
				local time_b = get_buffer_time(b.id)

				-- Compare the times, considering possible nil values
				return time_a > time_b
			end,
		},
	},
}
