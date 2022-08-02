"markdown
Plug 'vim-pandoc/vim-pandoc-syntax'
Plug 'tpope/vim-markdown'


" --- Markdown specific ---
let g:markdown_fenced_languages = ['css', 'javascript', 'js=javascript', 'json=javascript', 'sass','sh=bash','bash', 'vim', 'xml','sql','cs']

function LoadedMarkdown()

function! Mdftinit()
  setlocal spell spelllang=en_us
  " set filetype=markdown.pandoc
  let g:pandoc#syntax#codeblocks#embeds#langs = ["vim=vim"]
  " echom 'loade nmd'
endfunction
augroup pandoc_syntax
  au! BufNewFile,BufFilePre,BufRead *.md call Mdftinit()
augroup END
endfunction

augroup LoadedMarkdown
  autocmd!
  autocmd User PlugLoaded call LoadedMarkdown()
augroup END

