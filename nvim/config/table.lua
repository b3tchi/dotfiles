-- Pipe-table edits for the TableMode hydra (plugins/hydra.lua).
-- vim-table-mode has no swap/clear and only partial add/delete, so rows are
-- parsed here (cells split on unescaped |), edited, written back and then
-- realigned by table-mode. Border lines (|---|:--|) are skipped for cell/row
-- moves and kept in step for column edits.
local M = {}

local ESC = "\1"

local function is_row(line)
	return line:match("^%s*|") ~= nil
end

local function is_border(line)
	return line:match("^%s*|[%s%-:|+]*|%s*$") ~= nil and line:find("-", 1, true) ~= nil
end

local function split(line)
	local indent, inner = line:gsub("\\|", ESC):match("^(%s*)|(.*)$")
	inner = inner:gsub("|%s*$", "")
	local cells = {}
	for cell in (inner .. "|"):gmatch("(.-)|") do
		cells[#cells + 1] = vim.trim(cell:gsub(ESC, "\\|"))
	end
	return indent, cells
end

local function join(indent, cells)
	return indent .. "| " .. table.concat(cells, " | ") .. " |"
end

-- first/last line of the table around the cursor
local function bounds(lnum)
	if not is_row(vim.fn.getline(lnum)) then
		return nil
	end
	local first, last = lnum, lnum
	while first > 1 and is_row(vim.fn.getline(first - 1)) do
		first = first - 1
	end
	while last < vim.fn.line("$") and is_row(vim.fn.getline(last + 1)) do
		last = last + 1
	end
	return first, last
end

local function column_at(line, col)
	local before = line:sub(1, col):gsub("\\|", ESC)
	local _, bars = before:gsub("|", "")
	return math.max(bars, 1)
end

local function context()
	local lnum, col = vim.fn.line("."), vim.fn.col(".")
	local first, last = bounds(lnum)
	if not first then
		vim.notify("not in a table", vim.log.levels.WARN)
		return nil
	end
	return { lnum = lnum, ci = column_at(vim.fn.getline(lnum), col), first = first, last = last }
end

-- nearest non-border row from lnum in direction dir, inside the table
local function neighbour_row(ctx, lnum, dir)
	local l = lnum + dir
	while l >= ctx.first and l <= ctx.last do
		if not is_border(vim.fn.getline(l)) then
			return l
		end
		l = l + dir
	end
end

local function set_line(lnum, indent, cells)
	vim.fn.setline(lnum, join(indent, cells))
end

local function realign_to(lnum, ci)
	vim.fn.cursor(lnum, 1)
	vim.fn["tablemode#table#Realign"](".")
	local line = vim.fn.getline(lnum):gsub("\\|", ESC)
	local pos, n = 0, 0
	while n < ci do
		pos = line:find("|", pos + 1, true)
		if not pos then
			return
		end
		n = n + 1
	end
	vim.fn.cursor(lnum, pos + 2)
end

local function each_line(ctx, fn)
	for l = ctx.first, ctx.last do
		local line = vim.fn.getline(l)
		local indent, cells = split(line)
		fn(l, indent, cells, is_border(line))
		set_line(l, indent, cells)
	end
end

local function header_end(ctx)
	for l = ctx.first, ctx.last do
		if is_border(vim.fn.getline(l)) then
			return l
		end
	end
	return ctx.first - 1
end

-- cell -----------------------------------------------------------------------

function M.cell_swap(dir)
	local ctx = context()
	if not ctx then
		return
	end
	local indent, cells = split(vim.fn.getline(ctx.lnum))
	if dir == "h" or dir == "l" then
		local cj = ctx.ci + (dir == "l" and 1 or -1)
		if not cells[cj] then
			return
		end
		cells[ctx.ci], cells[cj] = cells[cj], cells[ctx.ci]
		set_line(ctx.lnum, indent, cells)
		return realign_to(ctx.lnum, cj)
	end
	local other = neighbour_row(ctx, ctx.lnum, dir == "j" and 1 or -1)
	if not other then
		return
	end
	local oindent, ocells = split(vim.fn.getline(other))
	cells[ctx.ci], ocells[ctx.ci] = ocells[ctx.ci] or "", cells[ctx.ci]
	set_line(ctx.lnum, indent, cells)
	set_line(other, oindent, ocells)
	realign_to(other, ctx.ci)
end

function M.cell_clear()
	local ctx = context()
	if not ctx then
		return
	end
	local indent, cells = split(vim.fn.getline(ctx.lnum))
	cells[ctx.ci] = ""
	set_line(ctx.lnum, indent, cells)
	realign_to(ctx.lnum, ctx.ci)
end

-- y/d/p go through vim.v.register, so "+ and clipboard=unnamedplus work
function M.cell_yank(cut)
	local ctx = context()
	if not ctx then
		return
	end
	local indent, cells = split(vim.fn.getline(ctx.lnum))
	vim.fn.setreg(vim.v.register, (cells[ctx.ci] or ""):gsub("\\|", "|"), "c")
	if cut then
		cells[ctx.ci] = ""
		set_line(ctx.lnum, indent, cells)
		realign_to(ctx.lnum, ctx.ci)
	end
end

function M.cell_paste()
	local ctx = context()
	if not ctx then
		return
	end
	local text = vim.fn.getreg(vim.v.register):gsub("\n", " ")
	local indent, cells = split(vim.fn.getline(ctx.lnum))
	cells[ctx.ci] = vim.trim(text:gsub("\\?|", "\\|"))
	set_line(ctx.lnum, indent, cells)
	realign_to(ctx.lnum, ctx.ci)
end

-- column ---------------------------------------------------------------------

function M.col_swap(dir)
	local ctx = context()
	if not ctx then
		return
	end
	local cj = ctx.ci + (dir == "l" and 1 or -1)
	if cj < 1 or cj > #select(2, split(vim.fn.getline(ctx.lnum))) then
		return
	end
	each_line(ctx, function(_, _, cells)
		cells[ctx.ci], cells[cj] = cells[cj], cells[ctx.ci]
	end)
	realign_to(ctx.lnum, cj)
end

function M.col_delete()
	local ctx = context()
	if not ctx then
		return
	end
	if #select(2, split(vim.fn.getline(ctx.lnum))) <= 1 then
		return
	end
	each_line(ctx, function(_, _, cells)
		table.remove(cells, ctx.ci)
	end)
	realign_to(ctx.lnum, math.max(ctx.ci - 1, 1))
end

function M.col_add(after)
	local ctx = context()
	if not ctx then
		return
	end
	local at = after and ctx.ci + 1 or ctx.ci
	each_line(ctx, function(_, _, cells, border)
		table.insert(cells, at, border and "---" or "")
	end)
	realign_to(ctx.lnum, at)
end

-- clears the body; header cells above the border stay
function M.col_clear()
	local ctx = context()
	if not ctx then
		return
	end
	local body = header_end(ctx)
	each_line(ctx, function(l, _, cells, border)
		if l > body and not border then
			cells[ctx.ci] = ""
		end
	end)
	realign_to(ctx.lnum, ctx.ci)
end

-- row ------------------------------------------------------------------------

function M.row_swap(dir)
	local ctx = context()
	if not ctx or is_border(vim.fn.getline(ctx.lnum)) then
		return
	end
	local other = neighbour_row(ctx, ctx.lnum, dir == "j" and 1 or -1)
	if not other then
		return
	end
	local a, b = vim.fn.getline(ctx.lnum), vim.fn.getline(other)
	vim.fn.setline(ctx.lnum, b)
	vim.fn.setline(other, a)
	realign_to(other, ctx.ci)
end

function M.row_delete()
	local ctx = context()
	if not ctx then
		return
	end
	vim.api.nvim_buf_set_lines(0, ctx.lnum - 1, ctx.lnum, false, {})
	local lnum = math.min(ctx.lnum, ctx.last - 1)
	if lnum >= ctx.first then
		realign_to(lnum, ctx.ci)
	end
end

function M.row_add(below)
	local ctx = context()
	if not ctx then
		return
	end
	local indent, cells = split(vim.fn.getline(ctx.lnum))
	local empty = {}
	for i = 1, #cells do
		empty[i] = ""
	end
	local lnum = below and ctx.lnum + 1 or ctx.lnum
	vim.api.nvim_buf_set_lines(0, lnum - 1, lnum - 1, false, { join(indent, empty) })
	realign_to(lnum, ctx.ci)
end

function M.row_clear()
	local ctx = context()
	if not ctx or is_border(vim.fn.getline(ctx.lnum)) then
		return
	end
	local indent, cells = split(vim.fn.getline(ctx.lnum))
	for i = 1, #cells do
		cells[i] = ""
	end
	set_line(ctx.lnum, indent, cells)
	realign_to(ctx.lnum, ctx.ci)
end

return M
