" Plug 'vimwiki/vimwiki'
" --- Vim Wiki ---
nnoremap <silent><space>Wt :VimwikiTable 1 2

" --- vimWiki specific ---
let wikis = [
  \ {'path': '~/vimwiki/', 'syntax': 'markdown', 'ext': '.md'}
  \]

" if g:computerName =='DESKTOP-HSRFLH5' "LEGO desktop
"   add(wikis ,{'path': '~/OneDrive - LEGO/vimwiki_LEGO/', 'syntax': 'markdown', 'ext': '.md'})
" endif

let g:vimwiki_markdown_link_ext = 1
let g:vimwiki_list = wikis
let g:vimwiki_listsyms = ' –x'
let g:vimwiki_listsym_rejected = 'x'
let g:vimwiki_folding = 'list'
let g:vimwiki_key_mappings = { 'table_mappings': 0 } "! - to fix/change completion behavior
