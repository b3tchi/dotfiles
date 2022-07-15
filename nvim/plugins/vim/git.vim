Plug 'tpope/vim-fugitive' "git intergration
Plug 'airblade/vim-gitgutter' "git intergration
Plug 'idanarye/vim-merginal' "git branch management TUI
Plug 'rbong/vim-flog' "git tree

function LoadedGit()

  source ~/dotfiles/nvim/scripts/vim/fugidiff.vim

  autocmd FileType fugitive nmap <buffer> j ):call DiffTog(1)<cr>
  autocmd FileType fugitive nmap <buffer> k (:call DiffTog(1)<cr>
  autocmd FileType fugitive nmap <buffer><silent> dd :call DiffTog(0)<CR>
  autocmd FileType fugitive nmap <buffer><silent> l :call NextChange()<CR>
  autocmd FileType fugitive nmap <buffer><silent> h :call PrevChange()<CR>

  let g:which_key_map.g ={'name':'+git'}
  let g:which_key_map.g.g = 'fugitive'
  nnoremap <silent> <space>gg :tab G<cr>
  let g:which_key_map.g.C = 'commit&push'
  nnoremap <space>gC :w \| :G commit -a -m '' \| :G push<left><left><left><left><left><left><left><left><left><left><left>
  let g:which_key_map.g.c = 'commit'
  nnoremap <space>gc :G commit -m ''<left>
  let g:which_key_map.g.p = 'pull'
  nnoremap <silent> <space>gp :G pull<cr>
  let g:which_key_map.g.P = 'push'
  nnoremap <silent> <space>gP :G push<cr>
  let g:which_key_map.g.f = 'fetch'
  nnoremap <silent> <space>gf :G fetch<cr>
  let g:which_key_map.g.m = 'merge'
  nnoremap <silent> <space>gm :G merge<cr>
  let g:which_key_map.g.b = 'blame'
  nnoremap <silent> <space>gb :G blame<cr>
  let g:which_key_map.g.l = 'log'
  nnoremap <silent> <space>gl :Flog -format=%>\|(65)\ %>(65)\ %<(40,trunc)%s\ %>\|(120%)%ad\ %an%d -date=short<cr>
  " let g:which_key_map.g.w = 'worktree'
  " nnoremap <silent> <space>gw :lua require('telescope').extensions.git_worktree.git_worktrees()<cr>

  nnoremap <silent> <space>gj :GitGutterNextHunk<cr>
  nnoremap <silent> <space>gk :GitGutterPrevHunk<cr>
  nnoremap <silent> <space>gi :GitGutterPreviewHunk<cr>

endfunction

augroup LoadedGit
  autocmd!
  autocmd User PlugLoaded call LoadedGit()
augroup END
