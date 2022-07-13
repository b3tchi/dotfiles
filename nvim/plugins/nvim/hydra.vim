Plug 'anuvyklack/hydra.nvim'
Plug 'anuvyklack/keymap-layer.nvim'

"For windows hydra
Plug 'sindrets/winshift.nvim'
Plug 'mrjones2014/smart-splits.nvim'

function LoadedHydra()

lua << EOF
local Hydra = require('hydra')
local splits = require('smart-splits')

local function choose_buffer()
  if #vim.fn.getbufinfo({ buflisted = true }) > 1 then
    buffer_hydra:activate()
  end
end

local function cmd(command)
  return table.concat({ '<Cmd>', command, '<CR>' })
end

-- vim.keymap.set(n, 'gb', choose_buffer)

local hintw = [[
 ^^^^^^     Move     ^^^^^^   ^^    Size   ^^   ^^     Split
 ^^^^^^--------------^^^^^^   ^^-----------^^   ^^---------------
 ^ ^ _k_ ^ ^   ^ ^ _K_ ^ ^    ^   _<C-k>_   ^   _s_: horizontally
 _h_ ^ ^ _l_   _H_ ^ ^ _L_    _<C-h>_ _<C-l>_   _v_: vertically
 ^ ^ _j_ ^ ^   ^ ^ _J_ ^ ^    ^   _<C-j>_   ^   _q_: close
 focus^^^^^^   window^^^^^^   ^ _=_ equalize^   _b_: choose buffer
]]

Hydra({
   name = 'WINDOWS',
   hint = hintw,
   config = {
      timeout = 4000,
      hint = {
         border = 'rounded',
         position = 'middle'
      }
   },
   mode = 'n',
   body = '<C-w>',
   heads = {
      { 'h', '<C-w>h' },
      { 'j', '<C-w>j' },
        { 'k', cmd [[try | wincmd k | catch /^Vim\%((\a\+)\)\=:E11:/ | close | endtry]] },
      { 'l', '<C-w>l' },

      { 'H', cmd 'WinShift left' },
      { 'J', cmd 'WinShift down' },
      { 'K', cmd 'WinShift up' },
      { 'L', cmd 'WinShift right' },

      { '<C-h>', function() splits.resize_left(2)  end },
      { '<C-j>', function() splits.resize_down(2)  end },
      { '<C-k>', function() splits.resize_up(2)    end },
      { '<C-l>', function() splits.resize_right(2) end },

      { '=', '<C-w>=', { desc = 'equalize'} },
      { 's', '<C-w>s' },
      { 'v', '<C-w>v' },
      { 'b', choose_buffer, { exit = true, desc = 'choose buffer' } },
      { 'q', cmd [[try | close | catch /^Vim\%((\a\+)\)\=:E444:/ | endtry]] },
      { '<Esc>', nil,  { exit = true, desc = false } }
   }
})

local hint = [[
  _f_: files       _m_: marks
  _o_: old files   _g_: live grep
  _p_: projects    _/_: search in file

  _h_: vim help    _c_: execute command
  _k_: keymap      _;_: commands history
  _r_: registers   _?_: search history

  _<Enter>_: Telescope           _<Esc>_
]]

Hydra({
   name = 'Telescope',
   hint = hint,
   config = {
      color = 'teal',
      invoke_on_body = true,
      hint = {
         position = 'middle',
         border = 'rounded',
      },
   },
   mode = 'n',
   body = '<leader>f',
   heads = {
      { 'f', cmd 'Telescope find_files' },
      { 'g', cmd 'Telescope live_grep' },
      { 'h', cmd 'Telescope help_tags', { desc = 'Vim help' } },
      { 'o', cmd 'Telescope oldfiles', { desc = 'Recently opened files' } },
      { 'm', cmd 'MarksListBuf', { desc = 'Marks' } },
      { 'k', cmd 'Telescope keymaps' },
      { 'r', cmd 'Telescope registers' },
      { 'p', cmd 'Telescope projects', { desc = 'Projects' } },
      { '/', cmd 'Telescope current_buffer_fuzzy_find', { desc = 'Search in file' } },
      { '?', cmd 'Telescope search_history',  { desc = 'Search history' } },
      { ';', cmd 'Telescope command_history', { desc = 'Command-line history' } },
      { 'c', cmd 'Telescope commands', { desc = 'Execute command' } },
      { '<Enter>', cmd 'Telescope', { exit = true, desc = 'List all pickers' } },
      { '<Esc>', nil, { exit = true, nowait = true } },
   }
})
EOF

endfunction

augroup LoadedHydra
  autocmd!
  autocmd User PlugLoaded call LoadedHydra()
augroup END
