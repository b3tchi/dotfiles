Plug 'kevinhwang91/nvim-ufo'
Plug 'kevinhwang91/promise-async'

set termguicolors
set background=dark
let g:gruvbox_italic=1
highlight Folded guibg=#232323

" echom "plugfile"

function LoadedUfo()
lua << EOF

  vim.wo.foldcolumn = '1'
  vim.wo.foldlevel = 99 -- feel free to decrease the value
  vim.wo.foldenable = true

  -- option 1: coc.nvim as LSP client
  -- use {'neoclide/coc.nvim', branch = 'master', run = 'yarn install --frozen-lockfile'}
  --

  -- option 2: nvim lsp as LSP client
  -- tell the server the capability of foldingRange
  -- nvim hasn't added foldingRange to default capabilities, users must add it manually
  _G.ufo_capabilities = vim.lsp.protocol.make_client_capabilities()

  ufo_capabilities.textDocument.foldingRange = {
    dynamicRegistration = false,
    lineFoldingOnly = true
  }


  -- setup for lang servers without files
  -- moved to lualsp
  -- local language_servers = {'vimls', 'remark_ls'}
  -- for _, ls in ipairs(language_servers) do
  --   require('lspconfig')[ls].setup({
  --     capabilities = ufo_capabilities,
  --   })
  -- end

  local handler = function(virtText, lnum, endLnum, width, truncate)
    local newVirtText = {}
    local suffix = ('  %d '):format(endLnum - lnum)
    local sufWidth = vim.fn.strdisplaywidth(suffix)
    local targetWidth = width - sufWidth
    local curWidth = 0
    for _, chunk in ipairs(virtText) do
      local chunkText = chunk[1]
      local chunkWidth = vim.fn.strdisplaywidth(chunkText)
      if targetWidth > curWidth + chunkWidth then
        table.insert(newVirtText, chunk)
      else
        chunkText = truncate(chunkText, targetWidth - curWidth)
        local hlGroup = chunk[2]
        table.insert(newVirtText, {chunkText, hlGroup})
        chunkWidth = vim.fn.strdisplaywidth(chunkText)
        -- str width returned from truncate() may less than 2nd argument, need padding
        if curWidth + chunkWidth < targetWidth then
          suffix = suffix .. (' '):rep(targetWidth - curWidth - chunkWidth)
        end
        break
      end
      curWidth = curWidth + chunkWidth
    end
    table.insert(newVirtText, {suffix, 'MoreMsg'})
    return newVirtText
end

  require('ufo').setup({
    fold_virt_text_handler = handler
  })
  -- require("scrollbar").setup()
  -- require("scrollbar.handlers.search").setup()
EOF
  " echom "gruvRun"
  " colorscheme gruvbox
endfunction

augroup LoadedUfo
  autocmd!
  autocmd User PlugLoaded call LoadedUfo()
augroup END
