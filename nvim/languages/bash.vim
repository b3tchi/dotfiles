"LSP Installed via nvim-lsp-installer
" :LSPInstall bashls
"DAP in vimspector only not yet in nvim-Dap only in vimspector

lua << EOF
-- BASH

require'lspconfig'.bashls.setup{
  on_attach = on_attach_default,
  capabilities = lsp_capabilities,
  flags = {
    debounce_text_changes = 150,
  },
}

function _G.mdblock_bash(mdblock, mdpath)

    --prepare bash
    local block_header = {
        '#!/bin/bash'
        ,'#get notes root'
        ,"NOTES_ROOT='" .. mdpath .. "/'"
        ,'if [[ -f "${NOTES_ROOT}.env" ]]; then'
        ,'     source "${NOTES_ROOT}.env"'
        ,'fi'
        ,'#look for active branch in tmux'
        ,'ATTACHED_BRANCH="$(tmx attached-branch-path --project-root-path "$PROJECT_ROOT")"'
        ,'#try to find environment variables'
        ,'if [[ ! -z ${ATTACHED_BRANCH} ]]; then'
        ,'     if [[ ! -z ${YAML_VARS} ]]; then'
        ,'          eval "$(ad pipe var load-to-env --vars-yaml "$PROJECT_ROOT$ATTACHED_BRANCH$YAML_VARS")"'
        ,'    fi'
        ,'fi'
        ,'#----END of automatic header----'
    }
    local temp_path = lux_temppath() .. tmp_file('sh')

    vim.fn.writefile(block_header, temp_path)
    vim.fn.writefile(mdblock, temp_path, 'a')

    local cmd = "bash '" .. temp_path .. "'"

    vim.fn.VimuxRunCommand(cmd)

end

EOF

function LoadedBashLang()
  autocmd FileType sh nnoremap <buffer> <space>o :Telescope lsp_document_symbols<CR>
endfunction

augroup LoadedBashLang
  autocmd!
  autocmd User PlugLoaded call LoadedBashLang()
augroup END

