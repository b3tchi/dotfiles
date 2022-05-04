Plug 'tpope/vim-dadbod'
Plug 'kristijanhusak/vim-dadbod-ui'
Plug 'kristijanhusak/vim-dadbod-completion'

"dadbod UI
let g:db_ui_disable_mappings = 1
let g:which_key_map.d ={'name':'+dadbod-ui'}




nnoremap <space>dn :DBUIToggle<CR>
let g:which_key_map.d.n = 'navpane'
nnoremap <space>dh :help DBUI<CR>
let g:which_key_map.d.h = 'help'
nnoremap <space>dc :call v:lua.Opencnfile()<CR>
let g:which_key_map.d.c = 'open connection file'

lua <<EOF
function _G.Opencnfile()
  local cnpath = vim.g.db_ui_save_location .. '/connections.json'
  vim.api.nvim_command('split '.. cnpath)
  return
end
EOF

" --- DadBod UI ---
let g:db_ui_disable_mappings = 1

autocmd FileType sql vmap <buffer><silent><space>de <Plug>(DBUI_ExecuteQuery)
autocmd FileType sql nmap <buffer><silent><space>de <Plug>(DBUI_ExecuteQuery)
let g:which_key_map.d.e = 'execute query'
autocmd FileType sql nmap <buffer><silent><space>dw <Plug>(DBUI_SaveQuery)
let g:which_key_map.d.s = 'save query'

autocmd FileType sql nmap <buffer><silent><space>dw <Plug>(DBUI_SaveQuery)
autocmd FileType sql nmap <buffer><silent><space>da :DBUIFindBuffer<CR>

" autocmd FileType dbui nmap <buffer> <S-k> <Plug>(DBUI_GotoFirstSibling)
" autocmd FileType dbui nmap <buffer> <S-j> <Plug>(DBUI_GotoLastSibling)
" autocmd FileType dbui nmap <buffer> k <Plug>(DBUI_GotoPrevSibling)
" autocmd FileType dbui nmap <buffer> j <Plug>(DBUI_GotoNextSibling)

autocmd FileType dbui nmap <buffer> <S-k> <Plug>(DBUI_GotoFirstSibling)
autocmd FileType dbui nmap <buffer> <S-j> <Plug>(DBUI_GotoLastSibling)
autocmd FileType dbui nmap <buffer> k <up>
autocmd FileType dbui nmap <buffer> j <down>

autocmd FileType dbui nmap <buffer> A <Plug>(DBUI_AddConnection)
autocmd FileType dbui nmap <buffer> r <Plug>(DBUI_RenameLine)
autocmd FileType dbui nmap <buffer> h <Plug>(DBUI_GotoParentNode)
autocmd FileType dbui nmap <buffer> o <Plug>(DBUI_SelectLine)
autocmd FileType dbui nmap <buffer> l <Plug>(DBUI_GotoChildNode)
autocmd FileType dbui nmap <buffer> R <Plug>(DBUI_Redraw)
autocmd FileType dbui nmap <buffer> dd <Plug>(DBUI_DeleteLine)
autocmd FileType dbui nmap <buffer> q :DBUIToggle<CR>

nnoremap <space>dn :DBUIToggle<CR>

" --- Better White Space
let g:better_whitespace_filetypes_blacklist = [
  \ 'dbout'
  \ ]

function LoadedDadbod()

endfunction

augroup LoadedDadbod
  autocmd!
  autocmd User PlugLoaded call LoadedDadbod()
augroup END
