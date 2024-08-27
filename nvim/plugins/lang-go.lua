-- add cmp-emoji
return {
  {
    "mfussenegger/nvim-dap",
    event = "VeryLazy",
    config = function()
      local dap = require("dap")
      dap.adapters.delve = {
        type = "server",
        host = "127.0.0.1",
        port = "12345",
      }
      dap.configurations.go = {
        {
          type = "delve",
          name = "Attach remote v2",
          mode = "remote",
          request = "attach",
        },
      }
      vim.filetype.add({
        extension = {
          templ = "templ",
        },
      })
      -- Format current buffer using LSP.
      vim.api.nvim_create_autocmd({
        -- 'BufWritePre' event triggers just before a buffer is written to file.
        "BufWritePre",
        }, {
          pattern = { "*.templ" },
          callback = function()
            -- Format the current buffer using Neovim's built-in LSP (Language Server Protocol).
            vim.lsp.buf.format()
          end,
      })
      require("lspconfig").tailwindcss.setup({
        filetypes = {
          "templ",
          -- include any other filetypes where you need tailwindcss
        },
        init_options = {
          userLanguages = {
            templ = "html",
          },
        },
      })
    end,
  },
  --adding languages to tree-sitter
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      -- add tsx and treesitter
      vim.list_extend(opts.ensure_installed, {
        "templ",
        "html",
      })
    end,
  },
}
