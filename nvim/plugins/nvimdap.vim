Plug 'mfussenegger/nvim-dap'
Plug 'Pocco81/DAPInstall.nvim'
Plug 'rcarriga/nvim-dap-ui'
Plug 'theHamsta/nvim-dap-virtual-text'

"dap ui dependency
Plug 'nvim-treesitter/nvim-treesitter', {'do': ':TSUpdate'}

nnoremap <space>ud :lua require'dap'.continue()<CR>
nnoremap <space>uq :lua require'dap'.terminate()<CR>

nnoremap <space>utt :lua require'dap'.toggle_breakpoint()<CR>
nnoremap <space>utl :lua require'dap'.list_breakpoints()<CR>
nnoremap <space>utc :lua require'dap'.clear_breakpoints()<CR>

nmap <space>ur :lua require'dap'.repl.toggle()<CR>

nmap <space>uj :lua require'dap'.step_over()<CR>
nmap <space>ul :lua require'dap'.step_into()<CR>
nmap <space>uh :lua require'dap'.step_out()<CR>

autocmd FileType dap-repl nmap J :lua require'dap'.step_over()<CR>
autocmd FileType dap-repl nmap L :lua require'dap'.step_into()<CR>
autocmd FileType dap-repl nmap H :lua require'dap'.step_out()<CR>

function LoadedDap()
lua << EOF
-- print('daploaded')
local dap = require('dap')


dap.adapters.python = {
  type = 'executable';
  command = os.getenv('HOME') .. '/.virtualenvs/tools/bin/python';
  args = { '-m', 'debugpy.adapter' };
}

local function pwd() return io.popen("pwd"):lines()() end

-- dap.adapters.netcoredbg = {
--   type = "executable",
--   command = os.getenv('HOME').. "/.local/share/nvim/dapinstall/dnetcs/netcoredbg/netcoredbg",
--   args = {
--     "--interpreter=vscode",
--     string.format("--engineLogging=%s/netcoredbg.engine.log", XDG_CACHE_HOME),
--     string.format("--log=%s/netcoredbg.log", XDG_CACHE_HOME),
--   },
-- }

-- string.format("--engineLogging=%s/netcoredbg.engine.log", XDG_CACHE_HOME),
-- string.format("--log=%s/netcoredbg.log", XDG_CACHE_HOME),
dap.defaults.fallback.focus_terminal = true
dap.defaults.fallback.terminal_win_cmd = '50vsplit new'
dap.defaults.fallback.force_external_terminal = true
dap.defaults.fallback.external_terminal = {
  command = '/usr/bin/alacritty';
    args = {'-e'};
}
-- dap.configurations.cs = {
--   {
--     type = "netcoredbg",
--     name = "launch - netcoredbg",
--     request = "launch",
--     program = function()
--       local dll = io.popen("find bin/Debug/ -maxdepth 2 -name \"*.dll\"")
--       return pwd() .. "/" .. dll:lines()()
--     end,
--     stopAtEntry = false,
--     -- console = "externalTerminal",
--     console = "integratedTerminal",
--   },
--   {
--     type = "netcoredbg",
--     name = "attach - netcoredbg",
--     request = "attach",
--     processId = 171399,
--     -- processId = require'dap.utils'.pick_process,
--     -- program = function()
--     --   local dll = io.popen("find bin/Debug/ -maxdepth 2 -name \"*.dll\"")
--     --   return pwd() .. "/" .. dll:lines()()
--     -- end,
--     -- stopAtEntry = false,
--   },
-- }

require("nvim-dap-virtual-text").setup()
require("dapui").setup()

EOF
endfunction

augroup LoadedDap
  autocmd!
  autocmd User PlugLoaded call LoadedDap()
augroup END
