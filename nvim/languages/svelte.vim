" LSP List [https://github.com/neovim/nvim-lspconfig/blob/master/CONFIG.md#svelte]

" --- Svelte filetypes specific ---
if !exists('g:context_filetype#filetypes')
  let g:context_filetype#filetypes = {}
endif
let g:context_filetype#filetypes.svelte =
  \ [
  \ {'filetype' : 'javascript', 'start' : '<script>', 'end' : '</script>'}
  \ ,{'filetype' : 'css', 'start' : '<style>', 'end' : '</style>'}
  \ ]

if !exists('g:context_filetype#same_filetypes')
  let g:context_filetype#same_filetypes = {}
endif
let g:context_filetype#same_filetypes.svelte = 'html'

au! BufNewFile,BufRead *.svelte set ft=html

