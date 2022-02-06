Plug 'mfussenegger/nvim-dap'
Plug 'Pocco81/DAPInstall.nvim'

" nnoremap <space>ud :call vimspector#Launch()<CR>
nmap <space>ud :lua require'dap'.continue()<CR>
nmap <space>uq :lua require'dap'.terminate()<CR>
" nnoremap <space>uq :call vimspector#Reset()<CR>
" nnoremap <space>uc :call vimspector#Continue()<CR>
nmap <space>utt :lua require'dap'.toggle_breakpoint()<CR>
nmap <space>utl :lua require'dap'.list_breakpoints()<CR>
nmap <space>utc :lua require'dap'.clear_breakpoints()<CR>

" nnoremap <space>ut :call vimspector#ToggleBreakpoint()<CR>
" nnoremap <space>utc :call vimspector#ClearBreakpoints()<CR>
" nnoremap <space>utl :call vimspector#ClearBreakpoints()<CR>

"- :lua require'dap'.utils.pick_process()
" nmap <space>uh <Plug>VimspectorStepOut
nmap <space>uh :lua require'dap'.step_out()<CR>

" nmap <space>ul <Plug>VimspectorStepInto
nmap <space>ul :lua require'dap'.step_into()<CR>

" nmap <space>uj <Plug>VimspectorStepOver
nmap <space>uj :lua require'dap'.step_over()<CR>
nmap <space>ur :lua require'dap'.repl.toggle()<CR>

function LoadedDap()
lua << EOF
print('daploaded')
local dap = require('dap')

dap.defaults.fallback.focus_terminal = true
dap.defaults.fallback.terminal_win_cmd = '50vsplit new'

dap.adapters.python = {
  type = 'executable';
  command = os.getenv('HOME') .. '/.virtualenvs/tools/bin/python';
  args = { '-m', 'debugpy.adapter' };
}

local function pwd() return io.popen("pwd"):lines()() end

dap.adapters.netcoredbg = {
  type = "executable",
  command = os.getenv('HOME').. "/.local/share/nvim/dapinstall/dnetcs/netcoredbg/netcoredbg",
  args = {
    "--interpreter=vscode",
    string.format("--engineLogging=%s/netcoredbg.engine.log", XDG_CACHE_HOME),
    string.format("--log=%s/netcoredbg.log", XDG_CACHE_HOME),
  },
}

    -- string.format("--engineLogging=%s/netcoredbg.engine.log", XDG_CACHE_HOME),
    -- string.format("--log=%s/netcoredbg.log", XDG_CACHE_HOME),

dap.defaults.fallback.force_external_terminal = true
dap.defaults.fallback.external_terminal = {
  command = '/usr/bin/tmux';
    -- args = {'-e'};
}
dap.configurations.cs = {
  {
    type = "netcoredbg",
    name = "launch - netcoredbg",
    request = "launch",
    program = function()
      local dll = io.popen("find bin/Debug/ -maxdepth 2 -name \"*.dll\"")
      return pwd() .. "/" .. dll:lines()()
    end,
    stopAtEntry = false,
  },
}
EOF
endfunction

augroup LoadedDap
  autocmd!
  autocmd User PlugLoaded call LoadedDap()
augroup END
