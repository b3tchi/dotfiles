Plug 'mhinz/vim-startify' "fancty start screen for VIM and session manager
Plug 'itchyny/vim-gitbranch' "support function for startify
" Plug 'morhetz/gruvbox'

let g:startify_lists = [
  \ { 'type': 'sessions',  'header': ['   Sessions']       },
  \ { 'type': 'files',     'header': ['   MRU']            },
  \ { 'type': 'dir',       'header': ['   MRU '. getcwd()] },
  \ { 'type': 'bookmarks', 'header': ['   Bookmarks']      },
  \ { 'type': 'commands',  'header': ['   Commands']       },
  \ ]

function LoadedStartify()
  " autocmd User StartifyAllBuffersOpened call SetNeovimTitle()
  " autocmd User StartifyBufferOpened call SetNeovimTitle()

  function! SetNeovimTitle()
    let &titlestring = fnamemodify(v:this_session, ':t')
  endfunction

  " autocmd VimLeavePre * silent execute v:lua.SaveIfSessionExists()

 " function! gitrepo
  let g:which_key_map.v.l ={'name':'+sessions'}
  " nnoremap <silent> <space>ss :SSave<cr>
  " nnoremap <silent> <space>sd :SDelete<cr>
  " nnoremap <silent> <space>sc :SClose<cr>
  " nnoremap <silent> <space>sw :SSave! dotfiles<cr>:wqa<cr>

lua << EOF
  function _G.SaveIfSessionExists()

    local titlestring = vim.fn.fnamemodify(vim.v.this_session,':t')

    if vim.fn.len(titlestring) > 0 then
      vim.cmd('SSave! ' .. titlestring)
    end
  end
EOF

endfunction


augroup LoadedStartify
  autocmd!
  autocmd User PlugLoaded call LoadedStartify()
augroup END

