local Input = require("nui.input")
local event = require("nui.utils.autocmd").event
local Popup = require("nui.popup")

local M = {}

local stack = {}
local current_page = nil
local current_popup = nil
local selection_popup_ref = nil

-- Run cppman safely and capture output as lines, wrapped to width
local function run_cppman(manwidth, selection, selection_number)
	local num = selection_number or 1
	local safe_width = math.max(40, tonumber(manwidth) or 80)
	local cmd = string.format("echo %d | cppman '%s' 2>&1 | fold -s -w %d", num, selection, safe_width)

	local handle = io.popen(cmd)
	if not handle then
		return { "Error running cppman" }
	end

	local result = handle:read("*a")
	handle:close()

	local lines = {}
	for line in result:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end
	return #lines > 0 and lines or { "No output from cppman" }
end

-- Render cppman output into buffer
local function show_man_page(bufnr, manwidth, selection, selection_number)
	local lines = run_cppman(manwidth, selection, selection_number)

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- Buffer safety options
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true
	vim.bo[bufnr].filetype = "cppman"
	vim.bo[bufnr].keywordprg = "cppman"

	-- Window safety options
	vim.wo.wrap = false
	vim.wo.linebreak = true
	vim.wo.signcolumn = "no"
	vim.wo.number = false
	vim.wo.relativenumber = false
end

local function loadNewPage()
	if current_page ~= nil then
		table.insert(stack, current_page)
	end
	current_page = vim.fn.expand("<cWORD>")
	M.open_cppman_for(current_page)
end

local function backToPrevPage()
	if #stack == 0 then
		return
	end
	current_page = table.remove(stack)
	M.open_cppman_for(current_page)
end

M.setup = function()
	vim.api.nvim_create_user_command("CPPMan", function(args)
		if args.args ~= nil and #args.args > 1 then
			M.open_cppman_for(args.args)
		else
			M.input()
		end
	end, { nargs = "?" })
end

M.input = function()
	local input = Input({
		position = "50%",
		size = { width = 20 },
		border = {
			style = "double",
			text = { top = "[Search cppman]", top_align = "center" },
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:Normal",
		},
	}, {
		prompt = "> ",
		default_value = "",
		on_submit = function(value)
			M.open_cppman_for(value)
		end,
	})

	input:mount()
	input:on(event.BufLeave, function()
		input:unmount()
	end)

	vim.keymap.set("n", "q", ":q!<cr>", { silent = true, buffer = true })
	vim.keymap.set("n", "<ESC>", ":q!<cr>", { silent = true, buffer = true })
end

M.open_cppman_for = function(word_to_search)
	local options = (function()
		local handle = io.popen("cppman '" .. word_to_search .. "' 2>&1")
		if not handle then
			return {}
		end
		local result = handle:read("*a")
		handle:close()
		local opts = {}
		for line in result:gmatch("[^\r\n]+") do
			if line:match("^%d+%.") then
				local num, desc = line:match("^(%d+)%.%s*(.*)")
				table.insert(opts, {
					num = tonumber(num),
					text = desc,
					value = desc:match("^[^ ]+") or desc,
				})
			end
		end
		return opts
	end)()

	-- Close any existing popups
	if selection_popup_ref then
		pcall(function()
			selection_popup_ref:unmount()
		end)
		selection_popup_ref = nil
	end
	if current_popup then
		pcall(function()
			current_popup:unmount()
		end)
		current_popup = nil
	end

	-- Directly open if no options
	if #options == 0 then
		local popup = Popup({
			enter = true,
			focusable = true,
			border = { style = "double", text = { top = "[cppman]" } },
			position = "50%",
			size = { width = "90%", height = "80%" },
		})
		popup:mount()
		current_popup = popup

		local function refresh_cppman()
			if not vim.api.nvim_win_is_valid(popup.winid) then
				return
			end
			local win_width = vim.api.nvim_win_get_width(popup.winid)
			local manwidth = math.max(40, win_width - 4)
			vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, {})
			show_man_page(popup.bufnr, manwidth, word_to_search)
		end

		refresh_cppman()
		popup:on("WinResized", refresh_cppman)
		return
	end

	-- Selection popup
	local selection_popup = Popup({
		enter = true,
		focusable = true,
		border = { style = "double", text = { top = "[Select cppman entry]" } },
		position = "50%",
		size = { width = 80, height = math.min(20, #options + 2) },
	})
	selection_popup_ref = selection_popup
	selection_popup:mount()

	local lines = {}
	for _, opt in ipairs(options) do
		table.insert(lines, string.format("%2d. %s", opt.num, opt.text))
	end
	table.insert(lines, "")
	table.insert(lines, "Enter selection number (1-" .. #options .. "):")
	vim.api.nvim_buf_set_lines(selection_popup.bufnr, 0, -1, false, lines)

	local function handle_selection()
		local line = vim.api.nvim_get_current_line()
		local selection_num = tonumber(line:match("%d+"))
		if not (selection_num and selection_num >= 1 and selection_num <= #options) then
			vim.notify("Invalid selection", vim.log.levels.ERROR)
			return
		end

		local selected_option = options[selection_num]
		selection_popup:unmount()
		selection_popup_ref = nil

		local popup = Popup({
			enter = true,
			focusable = true,
			border = { style = "double", text = { top = "[cppman]" } },
			position = "50%",
			size = { width = "90%", height = "80%" },
		})
		popup:mount()
		current_popup = popup

		local function refresh_cppman()
			if not vim.api.nvim_win_is_valid(popup.winid) then
				return
			end
			local win_width = vim.api.nvim_win_get_width(popup.winid)
			local manwidth = math.max(40, win_width - 4)
			vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, {})
			show_man_page(popup.bufnr, manwidth, word_to_search, selection_num)
		end

		refresh_cppman()
		popup:on("WinResized", refresh_cppman)

		current_page = selected_option.value

		popup:on(event.BufLeave, function()
			popup:unmount()
			current_popup = nil
		end)

		vim.keymap.set("n", "q", ":q!<cr>", { silent = true, buffer = true, nowait = true })
		vim.keymap.set("n", "K", loadNewPage, { silent = true, buffer = true })
		vim.keymap.set("n", "<C-]>", loadNewPage, { silent = true, buffer = true })
		vim.keymap.set("n", "<2-LeftMouse>", loadNewPage, { silent = true, buffer = true })
		vim.keymap.set("n", "<C-o>", backToPrevPage, { silent = true, buffer = true })
		vim.keymap.set("n", "<RightMouse>", backToPrevPage, { silent = true, buffer = true })
	end

	vim.keymap.set("n", "<CR>", handle_selection, { silent = true, buffer = selection_popup.bufnr })
	vim.keymap.set("n", "q", function()
		selection_popup:unmount()
		selection_popup_ref = nil
	end, { silent = true, buffer = selection_popup.bufnr })
	vim.keymap.set("n", "<ESC>", function()
		selection_popup:unmount()
		selection_popup_ref = nil
	end, { silent = true, buffer = selection_popup.bufnr })

	vim.api.nvim_win_set_cursor(selection_popup.winid, { 1, 0 })
end

return M
