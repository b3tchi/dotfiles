" init.vim
Plug 'lukas-reineke/headlines.nvim'

function LoadedHeadlines()

lua << EOF
require("headlines").setup({
    markdown = {
      headline_highlights = false,
        -- headline_highlights = {'Headline1'},
        -- fat_headlines = false,
      },
    org = {
      headline_highlights = false,
      },
  })
EOF

endfunction

augroup LoadedHeadlines
  autocmd!
  autocmd User PlugLoaded call LoadedHeadlines()
augroup END
