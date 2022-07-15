Plug 'puremourning/vimspector'

nnoremap <space>ud :call vimspector#Launch()<CR>
nnoremap <space>uq :call vimspector#Reset()<CR>
nnoremap <space>uc :call vimspector#Continue()<CR>

nnoremap <space>ut :call vimspector#ToggleBreakpoint()<CR>
nnoremap <space>uT :call vimspector#ClearBreakpoints()<CR>

nmap <space>uk <Plug>VimspectorRestart
nmap <space>uh <Plug>VimspectorStepOut
nmap <space>ul <Plug>VimspectorStepInto
nmap <space>uj <Plug>VimspectorStepOver
