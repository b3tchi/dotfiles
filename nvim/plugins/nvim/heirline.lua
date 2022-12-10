local Plug = vim.fn['plug#']

Plug "rebelot/heirline.nvim"
Plug 'kyazdani42/nvim-web-devicons' --Recommended (for coloured icons)
Plug 'SmiteshP/nvim-navic'
--https://github.com/AstroNvim/AstroNvim/blob/main/lua/core/utils/status.lua

function Load_heirline()

    -- local statusline = {...}
    -- local winbar = {...}
    -- local tabline = {...}
    --ASTRO -MAIN
    -- require'heirline'.setup({
    --     plugins = {
    --         heirline = function(config)
    --             -- statusline
    --             config[1] = {
    --                 hl = { fg = "fg", bg = "bg" },
    --                 -- astronvim.status.component.mode(),
    --                 -- astronvim.status.component.git_branch(),
    --                 -- astronvim.status.component.file_info(
    --                 --   astronvim.is_available "bufferline.nvim" and { filetype = {}, filename = false, file_modified = false } or nil
    --                 -- ),
    --                 -- astronvim.status.component.git_diff(),
    --                 -- astronvim.status.component.diagnostics(),
    --                 -- astronvim.status.component.fill(),
    --                 -- astronvim.status.component.macro_recording(),
    --                 -- astronvim.status.component.fill(),
    --                 -- astronvim.status.component.lsp(),
    --                 -- astronvim.status.component.treesitter(),
    --                 -- astronvim.status.component.nav(),
    --                 -- astronvim.status.component.mode { surround = { separator = "right" } },
    --             }
    --
    --             -- winbar
    --             config[2] = {
    --                 fallthrough = false,
    --                 -- if the current buffer matches the following buftype or filetype, disable the winbar
    --                 {
    --                     condition = function()
    --                         return astronvim.status.condition.buffer_matches {
    --                             buftype = { "terminal", "prompt", "nofile", "help", "quickfix" },
    --                             filetype = { "NvimTree", "neo-tree", "dashboard", "Outline", "aerial" },
    --                         }
    --                     end,
    --                     init = function() vim.opt_local.winbar = nil end,
    --                 },
    --                 -- if the window is currently active, show the breadcrumbs
    --                 {
    --                     condition = astronvim.status.condition.is_active,
    --                     astronvim.status.component.breadcrumbs { hl = { fg = "winbar_fg", bg = "winbar_bg" } },
    --                 },
    --                 -- if the window is not currently active, show the file information
    --                 {
    --                     astronvim.status.component.file_info {
    --                         file_icon = { hl = false },
    --                         hl = { fg = "winbarnc_fg", bg = "winbarnc_bg" },
    --                         surround = false,
    --                     },
    --                 },
    --             }
    --
    --             -- return the final configuration table
    --             return config
    --         end,
    --     },
    -- })
    local conditions = require("heirline.conditions")
    local utils = require("heirline.utils")

    local colors = {
        bright_bg = utils.get_highlight("Folded").bg,
        bright_fg = utils.get_highlight("Folded").fg,
        red = utils.get_highlight("DiagnosticError").fg,
        dark_red = utils.get_highlight("DiffDelete").bg,
        green = utils.get_highlight("String").fg,
        blue = utils.get_highlight("Function").fg,
        gray = utils.get_highlight("NonText").fg,
        orange = utils.get_highlight("Constant").fg,
        purple = utils.get_highlight("Statement").fg,
        cyan = utils.get_highlight("Special").fg,
        diag_warn = utils.get_highlight("DiagnosticWarn").fg,
        diag_error = utils.get_highlight("DiagnosticError").fg,
        diag_hint = utils.get_highlight("DiagnosticHint").fg,
        diag_info = utils.get_highlight("DiagnosticInfo").fg,
        git_del = utils.get_highlight("diffRemoved").fg,
        git_add = utils.get_highlight("diffAdded").fg,
        git_change = utils.get_highlight("diffChanged").fg,
    }

    require('heirline').load_colors(colors)

    local ViMode = {
        -- get vim current mode, this information will be required by the provider
        -- and the highlight functions, so we compute it only once per component
        -- evaluation and store it as a component attribute
        init = function(self)
            self.mode = vim.fn.mode(1) -- :h mode()

            -- execute this only once, this is required if you want the ViMode
            -- component to be updated on operator pending mode
            if not self.once then
                vim.api.nvim_create_autocmd("ModeChanged", {
                    pattern = "*:*o",
                    command = 'redrawstatus'
                })
                self.once = true
            end
        end,
        -- Now we define some dictionaries to map the output of mode() to the
        -- corresponding string and color. We can put these into `static` to compute
        -- them at initialisation time.
        static = {
            mode_names = { -- change the strings if you like it vvvvverbose!
                n = "NORMAL",
                no = "N?",
                nov = "N?",
                noV = "N?",
                ["no\22"] = "N?",
                niI = "Ni",
                niR = "Nr",
                niV = "Nv",
                nt = "Nt",
                v = "V",
                vs = "Vs",
                V = "V_",
                Vs = "Vs",
                ["\22"] = "^V",
                ["\22s"] = "^V",
                s = "S",
                S = "S_",
                ["\19"] = "^S",
                i = "INSERT",
                ic = "Ic",
                ix = "Ix",
                R = "R",
                Rc = "Rc",
                Rx = "Rx",
                Rv = "Rv",
                Rvc = "Rv",
                Rvx = "Rv",
                c = "COMMAND",
                cv = "Ex",
                r = "...",
                rm = "M",
                ["r?"] = "?",
                ["!"] = "!",
                t = "T",
            },
            mode_colors = {
                n = "red" ,
                i = "green",
                v = "cyan",
                V =  "cyan",
                ["\22"] =  "cyan",
                c =  "orange",
                s =  "purple",
                S =  "purple",
                ["\19"] =  "purple",
                R =  "orange",
                r =  "orange",
                ["!"] =  "red",
                t =  "red",
            }
        },

        -- We can now access the value of mode() that, by now, would have been
        -- computed by `init()` and use it to index our strings dictionary.
        -- note how `static` fields become just regular attributes once the
        -- component is instantiated.
        -- To be extra meticulous, we can also add some vim statusline syntax to
        -- control the padding and make sure our string is always at least 2
        -- characters long. Plus a nice Icon.
        provider = function(self)
            return " %2("..self.mode_names[self.mode].."%)"
        end,
        -- Same goes for the highlight. Now the foreground will change according to the current mode.
        hl = function(self)
            local mode = self.mode:sub(1, 1) -- get only the first mode character
            return { fg = self.mode_colors[mode], bold = true, }
        end,
        -- Re-evaluate the component only on ModeChanged event!
        -- This is not required in any way, but it's there, and it's a small
        -- performance improvement.
        update = {
            "ModeChanged",
        },
    }

    local FileNameBlock = {
        -- let's first set up some attributes needed by this component and it's children
        init = function(self)
            self.filename = vim.api.nvim_buf_get_name(0)
        end,
    }
    -- We can now define some children separately and add them later

    local FileIcon = {
        init = function(self)
            local filename = self.filename
            local extension = vim.fn.fnamemodify(filename, ":e")
            self.icon, self.icon_color = require("nvim-web-devicons").get_icon_color(filename, extension, { default = true })
        end,
        provider = function(self)
            return self.icon and (self.icon .. " ")
        end,
        hl = function(self)
            return { fg = self.icon_color }
        end
    }

    local FileName = {
        provider = function(self)
            -- first, trim the pattern relative to the current directory. For other
            -- options, see :h filename-modifers
            local filename = vim.fn.fnamemodify(self.filename, ":.")
            if filename == "" then return "[No Name]" end
            -- now, if the filename would occupy more than 1/4th of the available
            -- space, we trim the file path to its initials
            -- See Flexible Components section below for dynamic truncation
            if not conditions.width_percent_below(#filename, 0.25) then
                filename = vim.fn.pathshorten(filename)
            end
            return filename
        end,
        hl = { fg = utils.get_highlight("Directory").fg },
    }

    local FileFlags = {
        {
            condition = function()
                return vim.bo.modified
            end,
            provider = "[+]",
            hl = { fg = "green" },
        },
        {
            condition = function()
                return not vim.bo.modifiable or vim.bo.readonly
            end,
            provider = "",
            hl = { fg = "orange" },
        },
    }

    -- Now, let's say that we want the filename color to change if the buffer is
    -- modified. Of course, we could do that directly using the FileName.hl field,
    -- but we'll see how easy it is to alter existing components using a "modifier"
    -- component

    local FileNameModifer = {
        hl = function()
            if vim.bo.modified then
                -- use `force` because we need to override the child's hl foreground
                return { fg = "cyan", bold = true, force=true }
            end
        end,
    }

    -- let's add the children to our FileNameBlock component
    FileNameBlock = utils.insert(FileNameBlock,
        FileIcon,
        utils.insert(FileNameModifer, FileName), -- a new table where FileName is a child of FileNameModifier
        unpack(FileFlags), -- A small optimisation, since their parent does nothing
        { provider = '%<'} -- this means that the statusline is cut here when there's not enough space
    )

    local FileType = {
        provider = function()
            return string.upper(vim.bo.filetype)
        end,
        hl = { fg = utils.get_highlight("Type").fg, bold = true },
    }

    local FileEncoding = {
        provider = function()
            local enc = (vim.bo.fenc ~= '' and vim.bo.fenc) or vim.o.enc -- :h 'enc'
            return enc ~= 'utf-8' and enc:upper()
        end
    }

    local FileFormat = {
        provider = function()
            local fmt = vim.bo.fileformat
            return fmt ~= 'unix' and fmt:upper()
        end
    }

    -- We're getting minimalists here!
    local Ruler = {
        -- %l = current line number
        -- %L = number of lines in the buffer
        -- %c = column number
        -- %P = percentage through file of displayed window
        provider = "%7(%l/%3L%):%2c %P",
    }

    local LSPActive = {
        condition = conditions.lsp_attached,
        update = {'LspAttach', 'LspDetach'},

        -- You can keep it simple,
        -- provider = " [LSP]",

        -- Or complicate things a bit and get the servers names
        provider  = function()
            local names = {}
            for _, server in pairs(vim.lsp.buf_get_clients(0)) do
                table.insert(names, server.name)
            end
            return " [" .. table.concat(names, " ") .. "]"
        end,
        hl = { fg = "green", bold = true },
    }

    local HelpFileName = {
        condition = function()
            return vim.bo.filetype == "help"
        end,
        provider = function()
            local filename = vim.api.nvim_buf_get_name(0)
            return vim.fn.fnamemodify(filename, ":t")
        end,
        hl = { fg = colors.blue },
    }
    -- local LSPMessages = {
    --     provider = require("lsp-status").status,
    --     hl = { fg = "gray" },
    -- }

    -- The easy way.
    local Navic = {
        condition = require("nvim-navic").is_available,
        provider = function()
            return require("nvim-navic").get_location({highlight=true})
        end,
        update = 'CursorMoved'
    }
    -- local Navic = {
    --     condition = require("nvim-navic").is_available,
    --     static = {
    --         -- create a type highlight map
    --         type_hl = {
    --             File          = " ",
    --             Module        = " ",
    --             Namespace     = " ",
    --             Package       = " ",
    --             Class         = " ",
    --             Method        = " ",
    --             Property      = " ",
    --             Field         = " ",
    --             Constructor   = " ",
    --             Enum          = "練",
    --             Interface     = "練",
    --             Function      = " ",
    --             Variable      = " ",
    --             Constant      = " ",
    --             String        = " ",
    --             Number        = " ",
    --             Boolean       = "◩ ",
    --             Array         = " ",
    --             Object        = " ",
    --             Key           = " ",
    --             Null          = "ﳠ ",
    --             EnumMember    = " ",
    --             Struct        = " ",
    --             Event         = " ",
    --             Operator      = " ",
    --             TypeParameter = " ",
    --         },
    --         -- bit operation dark magic, see below...
    --         enc = function(line, col, winnr)
    --             return bit.bor(bit.lshift(line, 16), bit.lshift(col, 6), winnr)
    --         end,
    --         -- line: 16 bit (65535); col: 10 bit (1023); winnr: 6 bit (63)
    --         dec = function(c)
    --             local line = bit.rshift(c, 16)
    --             local col = bit.band(bit.rshift(c, 6), 1023)
    --             local winnr = bit.band(c,  63)
    --             return line, col, winnr
    --         end
    --     },
    --     init = function(self)
    --         local data = require("nvim-navic").get_data() or {}
    --         local children = {}
    --         -- create a child for each level
    --         for i, d in ipairs(data) do
    --             -- encode line and column numbers into a single integer
    --             local pos = self.enc(d.scope.start.line, d.scope.start.character, self.winnr)
    --             local child = {
    --                 {
    --                     provider = d.icon,
    --                     hl = self.type_hl[d.type],
    --                 },
    --                 {
    --                     -- escape `%`s (elixir) and buggy default separators
    --                     provider = d.name:gsub("%%", "%%%%"):gsub("%s*->%s*", ''),
    --                     -- highlight icon only or location name as well
    --                     -- hl = self.type_hl[d.type],
    --
    --                     on_click = {
    --                         -- pass the encoded position through minwid
    --                         minwid = pos,
    --                         callback = function(_, minwid)
    --                             -- decode
    --                             local line, col, winnr = self.dec(minwid)
    --                             vim.api.nvim_win_set_cursor(vim.fn.win_getid(winnr), {line, col})
    --                         end,
    --                         name = "heirline_navic",
    --                     },
    --                 },
    --             }
    --             -- add a separator only if needed
    --             if #data > 1 and i < #data then
    --                 table.insert(child, {
    --                     provider = " > ",
    --                     hl = { fg = 'bright_fg' },
    --                 })
    --             end
    --             table.insert(children, child)
    --         end
    --         -- instantiate the new child, overwriting the previous one
    --         self.child = self:new(children, 1)
    --     end,
    --     -- evaluate the children containing navic components
    --     provider = function(self)
    --         return self.child:eval()
    --     end,
    --     hl = { fg = "gray" },
    --     update = 'CursorMoved'
    -- }
    local Diagnostics = {

        condition = conditions.has_diagnostics,

        static = {
            error_icon = vim.fn.sign_getdefined("DiagnosticSignError")[1].text,
            warn_icon = vim.fn.sign_getdefined("DiagnosticSignWarn")[1].text,
            info_icon = vim.fn.sign_getdefined("DiagnosticSignInfo")[1].text,
            hint_icon = vim.fn.sign_getdefined("DiagnosticSignHint")[1].text,
        },

        init = function(self)
            self.errors = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.ERROR })
            self.warnings = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.WARN })
            self.hints = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.HINT })
            self.info = #vim.diagnostic.get(0, { severity = vim.diagnostic.severity.INFO })
        end,

        update = { "DiagnosticChanged", "BufEnter" },

        {
            provider = "![",
        },
        {
            provider = function(self)
                -- 0 is just another output, we can decide to print it or not!
                return self.errors > 0 and (self.error_icon .. self.errors .. " ")
            end,
            hl = { fg = "diag_error" },
        },
        {
            provider = function(self)
                return self.warnings > 0 and (self.warn_icon .. self.warnings .. " ")
            end,
            hl = { fg = "diag_warn" },
        },
        {
            provider = function(self)
                return self.info > 0 and (self.info_icon .. self.info .. " ")
            end,
            hl = { fg = "diag_info" },
        },
        {
            provider = function(self)
                return self.hints > 0 and (self.hint_icon .. self.hints)
            end,
            hl = { fg = "diag_hint" },
        },
        {
            provider = "]",
        },
    }

    local Git = {
        condition = conditions.is_git_repo,

        init = function(self)
            self.status_dict = vim.b.gitsigns_status_dict
            self.has_changes = self.status_dict.added ~= 0 or self.status_dict.removed ~= 0 or self.status_dict.changed ~= 0
        end,

        hl = { fg = "orange" },


        {   -- git branch name
            -- provider = function(self)
                -- return " " .. self.status_dict.head
            provider = function()
                return ""
            end,
            hl = { bold = true }
        },
        -- You could handle delimiters, icons and counts similar to Diagnostics
        {
            condition = function(self)
                return self.has_changes
            end,
            provider = "("
        },
        {
            provider = function(self)
                local count = self.status_dict.added or 0
                return count > 0 and ("+" .. count)
            end,
            hl = { fg = "git_add" },
        },
        {
            provider = function(self)
                local count = self.status_dict.removed or 0
                return count > 0 and ("-" .. count)
            end,
            hl = { fg = "git_del" },
        },
        {
            provider = function(self)
                local count = self.status_dict.changed or 0
                return count > 0 and ("~" .. count)
            end,
            hl = { fg = "git_change" },
        },
        {
            condition = function(self)
                return self.has_changes
            end,
            provider = ")",
        },
    }

    local DAPMessages = {
        condition = function()
            local session = require("dap").session()
            return session ~= nil
        end,
        provider = function()
            return " " .. require("dap").status()
        end,
        hl = "Debug"
        -- see Click-it! section for clickable actions
    }

    local WorkDirFixed = {
        provider = function()
            local icon = (vim.fn.haslocaldir(0) == 1 and "l" or "g") .. " " .. " "
            local cwd = vim.fn.getcwd(0)
            cwd = vim.fn.fnamemodify(cwd, ":~")
            if not conditions.width_percent_below(#cwd, 0.25) then
                cwd = vim.fn.pathshorten(cwd)
            end
            local trail = cwd:sub(-1) == '/' and '' or "/"
            return icon .. cwd  .. trail
        end,
        hl = { fg = "blue", bold = true },
    }

    local TerminalName = {
        -- we could add a condition to check that buftype == 'terminal'
        -- or we could do that later (see #conditional-statuslines below)
        provider = function()
            local tname, _ = vim.api.nvim_buf_get_name(0):gsub(".*:", "")
            return " " .. tname
        end,
        hl = { fg = "blue", bold = true },
    }

    local WorkDirFlexible = {
        init = function(self)
            self.icon = (vim.fn.haslocaldir(0) == 1 and "l" or "g") .. " " .. " "
            local cwd = vim.fn.getcwd(0)
            self.cwd = vim.fn.fnamemodify(cwd, ":~")
        end,
        hl = { fg = "blue", bold = true },

        flexible = 1,

        {
            -- evaluates to the full-lenth path
            provider = function(self)
                local trail = self.cwd:sub(-1) == "/" and "" or "/"
                return self.icon .. self.cwd .. trail .." "
            end,
        },
        {
            -- evaluates to the shortened path
            provider = function(self)
                local cwd = vim.fn.pathshorten(self.cwd)
                local trail = self.cwd:sub(-1) == "/" and "" or "/"
                return self.icon .. cwd .. trail .. " "
            end,
        },
        {
            -- evaluates to "", hiding the component
            provider = "",
        }
    }

    local Align = { provider = "%=" }
    local Space = { provider = " " }
    -- local Test = { provider = "test " }

    local DefaultStatusline = {
        ViMode, Space,
        -- FileNameBlock, Space,
        -- WorkDirFlexible, Space,
        Diagnostics, Space,
        Git, Space,
        -- Navic, Space,

        Align,
        DAPMessages, Align,
        LSPActive, Space,
        FileType, Space,
        Ruler,
    }

    local InactiveStatusline = {
        condition = conditions.is_not_active,
        Git, Space,
        Align,
        Ruler,
        -- FileType, Space, FileName, Align,
        -- FileNameBlock
    }

    local SpecialStatusline = {
        condition = function()
            return conditions.buffer_matches({
                buftype = { "nofile", "prompt", "help", "quickfix" },
                filetype = { "^git.*", "fugitive" },
            })
        end,

        FileType, Space, HelpFileName, Align
    }

    local TerminalStatusline = {

        condition = function()
            return conditions.buffer_matches({ buftype = { "terminal" } })
        end,

        hl = { bg = "dark_red" },

        -- Quickly add a condition to the ViMode to only show it when buffer is active!
        { condition = conditions.is_active, ViMode, Space }, FileType, Space, TerminalName, Align,
    }

    local StatusLines = {

        hl = function()
            if conditions.is_active() then
                return "StatusLine"
            else
                return "StatusLineNC"
            end
        end,

        -- the first statusline with no condition, or which condition returns true is used.
        -- think of it as a switch case with breaks to stop fallthrough.
        fallthrough = false,

        SpecialStatusline, TerminalStatusline, InactiveStatusline, DefaultStatusline,
    }

    local WinBars = {
        fallthrough = false,
        {   -- Hide the winbar for special buffers
            condition = function()
                return conditions.buffer_matches({
                    buftype = { "nofile", "prompt", "help", "quickfix" },
                    filetype = { "^git.*", "fugitive" },
                })
            end,
            init = function()
                vim.opt_local.winbar = nil
            end
        },
        {   -- A special winbar for terminals
            condition = function()
                return conditions.buffer_matches({ buftype = { "terminal" } })
            end,
            FileType, Space, TerminalName,
        },
        {   -- An inactive winbar for regular files
            condition = conditions.is_not_active,
            FileNameBlock, Space
        },
        -- A winbar for regular files
        {FileNameBlock, Space, Navic}
    }


    local TablineBufnr = {
        provider = function(self)
            return tostring(self.bufnr) .. ". "
        end,
        hl = "Comment",
    }

    -- we redefine the filename component, as we probably only want the tail and not the relative path
    local TablineFileName = {
        provider = function(self)
            -- self.filename will be defined later, just keep looking at the example!
            local filename = self.filename
            filename = filename == "" and "[No Name]" or vim.fn.fnamemodify(filename, ":t")
            return filename
        end,
        hl = function(self)
            return { bold = self.is_active or self.is_visible, italic = true }
        end,
    }

    -- this looks exactly like the FileFlags component that we saw in
    -- #crash-course-part-ii-filename-and-friends, but we are indexing the bufnr explicitly
    -- also, we are adding a nice icon for terminal buffers.
    local TablineFileFlags = {
        {
            condition = function(self)
                return vim.api.nvim_buf_get_option(self.bufnr, "modified")
            end,
            provider = "[+]",
            hl = { fg = "green" },
        },
        {
            condition = function(self)
                return not vim.api.nvim_buf_get_option(self.bufnr, "modifiable")
                    or vim.api.nvim_buf_get_option(self.bufnr, "readonly")
            end,
            provider = function(self)
                if vim.api.nvim_buf_get_option(self.bufnr, "buftype") == "terminal" then
                    return "  "
                else
                    return ""
                end
            end,
            hl = { fg = "orange" },
        },
    }

    -- Here the filename block finally comes together
    local TablineFileNameBlock = {
        init = function(self)
            self.filename = vim.api.nvim_buf_get_name(self.bufnr)
        end,
        hl = function(self)
            if self.is_active then
                return "TabLineSel"
            -- why not?
            -- elseif not vim.api.nvim_buf_is_loaded(self.bufnr) then
            --     return { fg = "gray" }
            else
                return "TabLine"
            end
        end,
        on_click = {
            callback = function(_, minwid, _, button)
                if (button == "m") then -- close on mouse middle click
                    vim.api.nvim_buf_delete(minwid, {force = false})
                else
                    vim.api.nvim_win_set_buf(0, minwid)
                end
            end,
            minwid = function(self)
                return self.bufnr
            end,
            name = "heirline_tabline_buffer_callback",
        },
        TablineBufnr,
        FileIcon, -- turns out the version defined in #crash-course-part-ii-filename-and-friends can be reutilized as is here!
        TablineFileName,
        TablineFileFlags,
    }

    -- a nice "x" button to close the buffer
    local TablineCloseButton = {
        condition = function(self)
            return not vim.api.nvim_buf_get_option(self.bufnr, "modified")
        end,
        { provider = " " },
        {
            provider = "",
            hl = { fg = "gray" },
            on_click = {
                callback = function(_, minwid)
                    vim.api.nvim_buf_delete(minwid, { force = false })
                end,
                minwid = function(self)
                    return self.bufnr
                end,
                name = "heirline_tabline_close_buffer_callback",
            },
        },
    }


    -- The final touch!
    local TablineBufferBlock = utils.surround({ "", "" }, function(self)
        if self.is_active then
            return utils.get_highlight("TabLineSel").bg
        else
            return utils.get_highlight("TabLine").bg
        end
    end, { TablineFileNameBlock, TablineCloseButton })
    -- local TablinePicker = {
    --     condition = function(self)
    --         return self._show_picker
    --     end,
    --     init = function(self)
    --         local bufname = vim.api.nvim_buf_get_name(self.bufnr)
    --         bufname = vim.fn.fnamemodify(bufname, ":t")
    --         local label = bufname:sub(1, 1)
    --         local i = 2
    --         while self._picker_labels[label] do
    --             if i > #bufname then
    --                 break
    --             end
    --             label = bufname:sub(i, i)
    --             i = i + 1
    --         end
    --         self._picker_labels[label] = self.bufnr
    --         self.label = label
    --     end,
    --     provider = function(self)
    --         return self.label
    --     end,
    --     hl = { fg = "red", bold = true },
    -- }

    vim.keymap.set("n", "gbp", function()
        local tabline = require("heirline").tabline
        local buflist = tabline._buflist[1]
        buflist._picker_labels = {}
        buflist._show_picker = true
        vim.cmd.redrawtabline()
        local char = vim.fn.getcharstr()
        local bufnr = buflist._picker_labels[char]
        if bufnr then
            vim.api.nvim_win_set_buf(0, bufnr)
        end
        buflist._show_picker = false
        vim.cmd.redrawtabline()
    end)

    local Tabpage = {
        provider = function(self)
            return "%" .. self.tabnr .. "T " .. self.tabnr .. " %T"
        end,
        hl = function(self)
            if not self.is_active then
                return "TabLine"
            else
                return "TabLineSel"
            end
        end,
    }

    local TabpageClose = {
        provider = "%999X  %X",
        hl = "TabLine",
    }

    local TabPages = {
        -- only show this component if there's 2 or more tabpages
        condition = function()
            return #vim.api.nvim_list_tabpages() >= 2
        end,
        { provider = "%=" },
        utils.make_tablist(Tabpage),
        TabpageClose,
    }
    -- and here we go
    local BufferLine = utils.make_buflist(
        TablineBufferBlock,
        { provider = "", hl = { fg = "gray" } }, -- left truncation, optional (defaults to "<")
        { provider = "", hl = { fg = "gray" } } -- right trunctation, also optional (defaults to ...... yep, ">")
        -- by the way, open a lot of buffers and try clicking them ;)
    )
    local TabLineOffset = {
        condition = function(self)
            local win = vim.api.nvim_tabpage_list_wins(0)[1]
            local bufnr = vim.api.nvim_win_get_buf(win)
            self.winid = win

            if vim.bo[bufnr].filetype == "NvimTree" then
                self.title = "NvimTree"
                return true
            elseif vim.bo[bufnr].filetype == "neo-tree" then
                self.title = "neo-tree"
                return true
            -- elseif vim.bo[bufnr].filetype == "TagBar" then
            --     ...
            end
        end,

        provider = function(self)
            local title = self.title
            local width = vim.api.nvim_win_get_width(self.winid)
            local pad = math.ceil((width - #title) / 2)
            return string.rep(" ", pad) .. title .. string.rep(" ", pad)
        end,

        hl = function(self)
            if vim.api.nvim_get_current_win() == self.winid then
                return "TablineSel"
            else
                return "Tabline"
            end
        end,
    }
    local TabLine = { TabLineOffset, BufferLine, TabPages }
    -- local TabLine = { TabLineOffset, BufferLine}
    -- local TabLine = { TablineFileNameBlock }
    -- local TabLine = {}

    require'heirline'.setup(StatusLines, WinBars, TabLine)

    vim.api.nvim_create_autocmd("User", {
        pattern = 'HeirlineInitWinbar',
        callback = function(args)
            local buf = args.buf
            local buftype = vim.tbl_contains(
                { "prompt", "nofile", "help", "quickfix" },
                vim.bo[buf].buftype
            )
            local filetype = vim.tbl_contains({ "gitcommit", "fugitive" }, vim.bo[buf].filetype)
            if buftype or filetype then
                vim.opt_local.winbar = nil
            end
        end,
    })

end

vim.api.nvim_create_autocmd(
    {'User'} ,{pattern='PlugLoaded'
        ,group=vim.api.nvim_create_augroup('AutoGroup_heirline',{clear = true})
        , callback=Load_heirline
    }
)

