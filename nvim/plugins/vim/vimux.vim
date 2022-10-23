Plug 'christoomey/vim-tmux-navigator'
Plug 'preservim/vimux'

function LoadedVimux()
    let g:which_key_map.c ={'name':'+console'}
    " let g:VimuxRunnerName = "vimuxout"

    let g:VimuxRunnerType = "pane"


    function! VimuxSlime()
        call VimuxRunCommand(@v, 0)
        " echom @v
    endfunction

lua << EOF

    function _G.vimux_md_block()

        local mdblock = {}

        if vim.bo.filetype == 'markdown' then
            mdblock = md_block_get()
        elseif vim.bo.filetype == 'org' then
            mdblock=org_block_get()
        else
            print('not covered format only .org or .md')
            return
        end

        -- "bash command
        if mdblock.lang == 'bash' then

            if type(mdblock_bash)=='function' then
                mdblock_bash(mdblock.code, mdblock.path)
            else
                print('not exists')
            end

            -- "powershell
        elseif mdblock.lang == 'powershell' then

            if type(mdblock_powershell)=='function' then
                mdblock_powershell(mdblock.code)
            else
                print('not exists')
            end

        elseif mdblock.lang == 'cs' or mdblock.lang == 'csharp' then

            if type(mdblock_csharp)=='function' then
                mdblock_csharp(mdblock.code)
            else
                print('not exists')
            end

        elseif mdblock.lang == 'pwsh' then

            if type(mdblock_pwsh)=='function' then
                mdblock_pwsh(mdblock.code)
            else
                print('not exists')
            end

        elseif mdblock.lang == 'vim' then

            if type(mdblock_vim)=='function' then
                mdblock_vim(mdblock.code)
            else
                print('not exists')
            end

        elseif mdblock.lang == 'lua' then

            if type(mdblock_lua)=='function' then
                mdblock_lua(mdblock.code)
            else
                print('not exists')
            end

        else
            print('not know code format')
        end
    end


    function _G.tmp_file( extension )

        local fname = os.date("%Y%m%d_%H%M%S") .. '.' .. extension

        return fname
    end

    function _G.winpath_from_wsl( winpath )

        local unx_tmpps = vim.fn.substitute(winpath,'\\','/','g')
        local unx_tmpps = vim.fn.substitute(unx_tmpps,'C:','/mnt/c','g')

        return unx_tmpps

    end

    function _G.lux_temppath()

        local temppath = '/tmp/nvim_mdblocks/'

        vim.fn.mkdir(temppath,'p')
        return temppath

    end

    function _G.win_temppath()

        local win_tmpps = vim.fn.trim(vim.fn.system('cd /mnt/c/ && cmd.exe /c echo %TEMP% && cd - | grep C: ')) .. '\\nvim_mdblocks\\'

        --create temp folder if not exists
        vim.fn.mkdir(winpath_from_wsl(win_tmpps),'p')

        return win_tmpps

    end

    function _G.md_block_get()

        local block_line_begin = vim.fn.search('^```[a-z0-9]*$', 'bnW')
        local block_line_end = vim.fn.search('^```$', 'nW')

        local resp = {}

        resp.lang = vim.fn.getline(block_line_begin):sub(4)
        resp.code = vim.fn.getline(block_line_begin + 1, block_line_end -1)
        resp.path = vim.fn.expand('%:p:h')

        return resp


    end

    function _G.org_block_get()

        local block_line_begin = vim.fn.search('#+begin_src [a-z0-9]*$', 'bnW')
        local block_line_end = vim.fn.search('#+end_src$', 'nW')

        local resp = {}

        resp.lang = vim.fn.matchlist(vim.fn.getline(block_line_begin),'\\(#+begin_src \\)\\(.*\\)\\?')[3]
        resp.code = vim.fn.getline(block_line_begin + 1, block_line_end -1)
        resp.path = vim.fn.expand('%:p:h')

        return resp

    end

EOF



    " function! FolderTemp()
    "     let temppath = '/tmp/nvim_mdblocks/'
    "     " !mkdir -p '/tmp/nvim_mdblocks/'
    "     call mkdir(temppath,'p')
    "     return temppath
    " endfunction

    " function! MarkdownBlock()
    "     let view = winsaveview()
    "     let line = line('.')
    "     let cpos = getpos('.')
    "     let start = search('^\s*[`~]\{3,}\S*\s*$', 'bnW')
    "     if !start
    "         return
    "     endif
    "
    "     call cursor(start, 1)
    "     let [fence, langv] = matchlist(getline(start), '\([`~]\{3,}\)\(\S\+\)\?')[1:2]
    "     let end = search('^\s*' . fence . '\s*$', 'nW')
    "
    "     if end < line""|| langidx < 0
    "         call winrestview(view)
    "         return
    "     endif
    "
    "     let resp = {}
    "     let resp.code = getline(start + 1, end - 1) ""block"" list2str(block)
    "     let resp.lang = langv
    "     call setpos('.',cpos)
    "     return resp
    "
    " endfunction

    nnoremap <silent> <space>co :VimuxOpenRunner<cr>
    nnoremap <silent> <space>cq :VimuxCloseRunner<cr>
    nnoremap <silent> <space>cl :VimuxRunLastCommand<cr>
    nnoremap <silent> <space>cx :VimuxInteruptRunner<cr>
    nnoremap <silent> <space>ci :VimuxInspectRunner<CR>
    nnoremap <silent> <space>cp :VimuxPromptCommand<CR>
    nnoremap <silent> <space>cc :VimuxRunCommand getline(".")<CR>
    nnoremap <silent> <space>cr vip "vy :call VimuxSlime()<CR>
    nnoremap <silent> <space>cb :lua vimux_md_block()<CR>

    " nnoremap <space>cz :lua require'telegraph'.telegraph({how='tmux_popup', cmd='man '})<Left><Left><Left>

    vmap <space>cr "vy :call VimuxSlime()<CR>

endfunction

augroup LoadedVimux
  autocmd!
  autocmd User PlugLoaded call LoadedVimux()
augroup END
