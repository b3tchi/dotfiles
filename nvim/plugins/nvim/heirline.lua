local Plug = vim.fn['plug#']

Plug "rebelot/heirline.nvim"
--https://github.com/AstroNvim/AstroNvim/blob/main/lua/core/utils/status.lua

function Load_diffview()

    -- local statusline = {...}
    -- local winbar = {...}
    -- local tabline = {...}
    require'heirline'.setup({
  plugins = {
    heirline = function(config)
      -- statusline
      config[1] = {
        hl = { fg = "fg", bg = "bg" },
        -- astronvim.status.component.mode(),
        -- astronvim.status.component.git_branch(),
        -- astronvim.status.component.file_info(
        --   astronvim.is_available "bufferline.nvim" and { filetype = {}, filename = false, file_modified = false } or nil
        -- ),
        -- astronvim.status.component.git_diff(),
        -- astronvim.status.component.diagnostics(),
        -- astronvim.status.component.fill(),
        -- astronvim.status.component.macro_recording(),
        -- astronvim.status.component.fill(),
        -- astronvim.status.component.lsp(),
        -- astronvim.status.component.treesitter(),
        -- astronvim.status.component.nav(),
        -- astronvim.status.component.mode { surround = { separator = "right" } },
      }

      -- winbar
      config[2] = {
        fallthrough = false,
        -- if the current buffer matches the following buftype or filetype, disable the winbar
        {
          condition = function()
            return astronvim.status.condition.buffer_matches {
              buftype = { "terminal", "prompt", "nofile", "help", "quickfix" },
              filetype = { "NvimTree", "neo-tree", "dashboard", "Outline", "aerial" },
            }
          end,
          init = function() vim.opt_local.winbar = nil end,
        },
        -- if the window is currently active, show the breadcrumbs
        {
          condition = astronvim.status.condition.is_active,
          astronvim.status.component.breadcrumbs { hl = { fg = "winbar_fg", bg = "winbar_bg" } },
        },
        -- if the window is not currently active, show the file information
        {
          astronvim.status.component.file_info {
            file_icon = { hl = false },
            hl = { fg = "winbarnc_fg", bg = "winbarnc_bg" },
            surround = false,
          },
        },
      }

      -- return the final configuration table
      return config
    end,
  },
})

    -- vim.keymap.set('n', '<space>bgh', '<Cmd>DiffviewFileHistory %<CR>', {silent = true, desc='buffer git history'})

end

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern='PlugLoaded'
        ,group=vim.api.nvim_create_augroup('AutoGroup_diffview',{clear = true})
        , callback=Load_diffview
    }
)

