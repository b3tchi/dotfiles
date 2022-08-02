Plug 'lewis6991/gitsigns.nvim'

"git clone
Plug 'nvim-lua/plenary.nvim'
Plug 'TimUntersberger/neogit'

"diffview
Plug 'nvim-lua/plenary.nvim' Plug 'sindrets/diffview.nvim'

function LoadedGitNvim()

lua << EOF

require('gitsigns').setup()

require('neogit').setup({ integrations = { -- Requires you to have
`sindrets/diffview.nvim` installed. diffview = true,
  },
})

require('diffview').setup()


EOF
let g:which_key_map.g ={'name':'+git'}

let g:which_key_map.g.g = 'neogit'
nnoremap <silent> <space>gg :Neogit<cr>

let g:which_key_map.g.p = 'pull'
nnoremap <silent> <space>gp :G pull<cr>

let g:which_key_map.g.P = 'push'
nnoremap <silent> <space>gP :G push<cr>

let g:which_key_map.g.f = 'fetch'
nnoremap <silent> <space>gf :G fetch<cr>

let g:which_key_map.g.m = 'merge'
nnoremap <silent> <space>gm :G merge<cr>

endfunction

augroup LoadedGitNvim
  autocmd!
  autocmd User PlugLoaded call LoadedGitNvim()
augroup END
