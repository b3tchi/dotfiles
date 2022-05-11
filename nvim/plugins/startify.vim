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
  autocmd User StartifyAllBuffersOpened call SetNeovimTitle()
  autocmd User StartifyBufferOpened call SetNeovimTitle()

  function! SetNeovimTitle()
    let &titlestring = fnamemodify(v:this_session, ':t')
  endfunction
endfunction

lua << EOF
  function _G.SaveIfSessionExists()

    local titlestring = vim.fn.fnamemodify(vim.v.this_session,':t')

    if vim.fn.len(titlestring) > 0 then
      vim.cmd('SSave! ' .. titlestring)
    end
  end
EOF

augroup LoadedStartify
  autocmd!
  autocmd User PlugLoaded call LoadedStartify()
  autocmd VimLeavePre * silent execute v:lua.SaveIfSessionExists()
augroup END

