return {
	"luukvbaal/statuscol.nvim",
	config = function()
		local builtin = require("statuscol.builtin")

		require("statuscol").setup({
			-- configuration goes here, for example:
			relculright = true,
			segments = {
				--other sighns
				{
					sign = { name = { ".*" }, maxwidth = 2, colwidth = 1, auto = true, wrap = true },
					click = "v:lua.ScSa",
				},
				-- Dap Breakpoints
				{
					sign = { name = { "DapBreakpoint" }, maxwidth = 1, colwidth = 1, auto = false, fillchars = "" },
					click = "v:lua.ScSa",
				},
				--Git Signs
				{
					sign = { namespace = { "gitsigns" }, maxwidth = 1, colwidth = 1, auto = false },
					click = "v:lua.ScSa",
				},
				--diagnostic messanges
				{
					sign = { name = { "Diagnostic.*" }, maxwidth = 2, auto = true },
					click = "v:lua.ScSa",
				},
				--Line numbers
				{ text = { builtin.lnumfunc }, click = "v:lua.ScLa" },
				--foldicons
				{ text = { builtin.foldfunc }, click = "v:lua.ScFa" },
			},
		})
	end,
	opts = {
		defaults = {
			lazy == false,
		},
	},
}
