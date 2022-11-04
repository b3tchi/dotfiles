"notes taking - NOT USED to be checked
Plug 'nvim-treesitter/nvim-treesitter'
Plug 'nvim-orgmode/orgmode'

"bullets plugins
Plug 'akinsho/org-bullets.nvim'

function LoadOrgMode()

lua << EOF

vim.opt.conceallevel = 2
vim.opt.concealcursor = 'nc'

require('orgmode').setup_ts_grammar()

-- Tree-sitter configuration
-- If TS highlights are not enabled at all, or disabled via `disable` prop, highlighting will fallback to default Vim syntax highlighting
require'nvim-treesitter.configs'.setup {
  highlight = {
    enable = true,
    additional_vim_regex_highlighting = {'org'}, -- Required for spellcheck, some LaTex highlights and code block highlights that do not have ts grammar
  },
  ensure_installed = {'org'}, -- Or run :TSUpdate org
}

require('orgmode').setup({
    org_agenda_files = {'~/wiki/org/**/*'},
    org_default_notes_file = '~/wiki/org/refile.org',
    org_hide_leading_stars = true,
    org_capture_templates = {
        -- j = {
        --     description = 'Journal',
        --     template = '* %<%Y-%m-%d> %<%A>\n** %?',
        --     target = '~/wiki/org/journal/%<%Y-%m-%d>.org'
        -- },
    },
})

-- require'cmp'.setup({
--   sources = {
--     { name = 'orgmode' }
--   }
-- })

require('org-bullets').setup()

-- function _G.journal_entry()
--     local journal_file = '~/wiki/org/journal/2210-23-7.org'
--     vim.fn.filewritable(journal_file)
--
-- end

-- vim.api.nvim_set_keymap('n', '<space>oj', '', { noremap = true, silent = true, callback = today_journal, desc='journal'})
vim.keymap.set('n', '<space>oj', function() return today_journal() end, {silent = true, desc='journal'})

function get_bufnr_by_name(buf_name)

    if (vim.fn.bufexists(buf_name) == 1 )then

        local buf_nr = vim.fn.filter(
            vim.fn.map(
                vim.api.nvim_list_bufs()
                , function(k,v) return {v,vim.api.nvim_buf_get_name(v)} end
                )
            , function(k,v) return v[2] == buf_name  end
            -- , function(k,v) return v[1] > 24 end
            )[1][1]
        return buf_nr
    else
        return -1
    end

end

function remove_buf_by_name(buf_name)

    local buf_nr=get_bufnr_by_name(buf_name)

    if (buf_nr ~= -1) then
        --fully remove buffer
        print(vim.api.nvim_buf_delete(buf_nr,{force=1}))

        --remove file
        print('removed - ' .. buf_name)
        return -1
    else
        print('not found - ' .. buf_name)
        return 0
    end

end

function add_buf(buf_name)

    local buf_nr=get_bufnr_by_name(buf_name)

    if (buf_nr == -1) then

        -- print(vim.fn.filewritable(buf_name))
        -- print(vim.fn.filereadable(buf_name))
        -- print(vim.fn.bufexists(buf_name))

        print('added - ' .. buf_name)
        return vim.fn.bufadd(buf_name)
    else

        print('already opened - ' .. buf_name)
        return buf_nr
    end

end


function vertical_split_win(win_nr)
    win_nr = win_nr or 0

    if (win_nr ~= 0) then
        vim.api.nvim_set_current_win(win_nr)
    end

    vim.cmd('split')
    local win = vim.api.nvim_get_current_win()
    return win
end

function _G.today_journal()
    local journal_file = vim.fn.expand('~/wiki/org/journals/' .. os.date('%y%m-%d-%w.org') .. '.org')

    local win_nr= vertical_split_win(0)

    print(get_bufnr_by_name(journal_file))

    local buf_nr = add_buf(journal_file)

    print(vim.api.nvim_win_set_buf(win_nr, buf_nr))
end


EOF

endfunction

augroup LoadOrgMode
  autocmd!
  autocmd User PlugLoaded call LoadOrgMode()
augroup END
