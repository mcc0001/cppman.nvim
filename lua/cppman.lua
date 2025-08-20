local Input = require("nui.input")
local event = require("nui.utils.autocmd").event
local Popup = require("nui.popup")

local M = {}

local state = {
	stack = {},
	current_page = nil,
	current_popup = nil,
	selection_popup = nil,
}

-- Safe execution of cppman command with proper output handling
local function run_cppman(manwidth, selection, selection_number)
	local safe_width = math.max(40, manwidth or 80)
	local cmd =
		string.format("echo %d | cppman '%s' 2>&1 | fold -s -w %d", selection_number or 1, selection, safe_width)

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

-- Configure buffer options for cppman content
local function configure_cppman_buffer(bufnr, winid)
	local bo = vim.bo[bufnr]
	bo.buftype = "nofile"
	bo.bufhidden = "wipe"
	bo.swapfile = false
	bo.modifiable = false
	bo.readonly = true
	bo.filetype = "cppman"
	bo.keywordprg = "cppman"

	-- Set window options specifically for the popup window
	vim.api.nvim_win_set_option(winid, "wrap", false)
	vim.api.nvim_win_set_option(winid, "linebreak", true)
	vim.api.nvim_win_set_option(winid, "signcolumn", "no")
	vim.api.nvim_win_set_option(winid, "number", false)
	vim.api.nvim_win_set_option(winid, "relativenumber", false)
end

-- Configure selection popup buffer
local function configure_selection_buffer(bufnr, winid)
	local bo = vim.bo[bufnr]
	bo.buftype = "nofile"
	bo.bufhidden = "wipe"
	bo.swapfile = false
	bo.modifiable = false
	bo.readonly = true
	bo.filetype = "cppman-select"

	-- Set window options specifically for the selection popup window
	vim.api.nvim_win_set_option(winid, "wrap", false)
	vim.api.nvim_win_set_option(winid, "linebreak", true)
	vim.api.nvim_win_set_option(winid, "signcolumn", "no")
	vim.api.nvim_win_set_option(winid, "number", false)
	vim.api.nvim_win_set_option(winid, "relativenumber", false)
end

-- Render cppman output into buffer
local function show_man_page(bufnr, winid, manwidth, selection, selection_number)
	local lines = run_cppman(manwidth, selection, selection_number)

	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	configure_cppman_buffer(bufnr, winid)
end

-- Navigation functions
local function load_new_page()
	if state.current_page and state.current_popup then
		table.insert(state.stack, state.current_page)
	end
	state.current_page = vim.fn.expand("<cWORD>")
	M.open_cppman_for(state.current_page)
end

local function back_to_prev_page()
	if #state.stack == 0 then
		return
	end
	state.current_page = table.remove(state.stack)
	M.open_cppman_for(state.current_page)
end

-- Parse cppman options from command output
local function parse_cppman_options(word_to_search)
	local handle = io.popen("cppman '" .. word_to_search .. "' 2>&1")
	if not handle then
		return {}
	end

	local result = handle:read("*a")
	handle:close()

	local options = {}
	for line in result:gmatch("[^\r\n]+") do
		if line:match("^%d+%.") then
			local num, desc = line:match("^(%d+)%.%s*(.*)")
			table.insert(options, {
				num = tonumber(num),
				text = desc,
				value = desc:match("^[^ ]+") or desc,
			})
		end
	end

	return options
end

-- Close popup safely
local function safe_popup_close(popup)
	if popup and pcall(function()
		popup:unmount()
	end) then
		if popup == state.current_popup then
			state.current_popup = nil
		end
		if popup == state.selection_popup then
			state.selection_popup = nil
		end
	end
end

-- Create and configure man page popup
local function create_man_popup(selection, selection_number)
	local popup = Popup({
		enter = true,
		focusable = true,
		border = { style = "double", text = { top = "[cppman]" } },
		position = "50%",
		size = { width = "90%", height = "80%" },
	})

	popup:mount()
	state.current_popup = popup

	local function refresh_cppman()
		if not vim.api.nvim_win_is_valid(popup.winid) then
			return
		end

		local win_width = vim.api.nvim_win_get_width(popup.winid)
		local manwidth = math.max(40, win_width - 4)

		vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, {})
		show_man_page(popup.bufnr, popup.winid, manwidth, selection, selection_number)
	end

	refresh_cppman()
	popup:on("WinResized", refresh_cppman)

	-- Setup popup keymaps
	vim.keymap.set("n", "q", function()
		safe_popup_close(state.current_popup)
	end, { silent = true, buffer = popup.bufnr, nowait = true })

	vim.keymap.set("n", "<ESC>", function()
		safe_popup_close(state.current_popup)
	end, { silent = true, buffer = popup.bufnr, nowait = true })

	vim.keymap.set("n", "K", load_new_page, { silent = true, buffer = popup.bufnr })
	vim.keymap.set("n", "<C-]>", load_new_page, { silent = true, buffer = popup.bufnr })
	vim.keymap.set("n", "<2-LeftMouse>", load_new_page, { silent = true, buffer = popup.bufnr })
	vim.keymap.set("n", "<C-o>", back_to_prev_page, { silent = true, buffer = popup.bufnr })
	vim.keymap.set("n", "<RightMouse>", back_to_prev_page, { silent = true, buffer = popup.bufnr })

	return popup
end

-- Create selection popup
local function create_selection_popup(options, word_to_search)
	local selection_popup = Popup({
		enter = true,
		focusable = true,
		border = { style = "double", text = { top = "[Select cppman entry]" } },
		position = "50%",
		size = { width = 80, height = math.min(20, #options + 2) },
	})

	selection_popup:mount()
	state.selection_popup = selection_popup

	local lines = {}
	for _, opt in ipairs(options) do
		table.insert(lines, string.format("%2d. %s", opt.num, opt.text))
	end
	table.insert(lines, "")
	table.insert(lines, "Enter selection number (1-" .. #options .. "):")

	vim.api.nvim_buf_set_lines(selection_popup.bufnr, 0, -1, false, lines)
	configure_selection_buffer(selection_popup.bufnr, selection_popup.winid)

	local function handle_selection()
		local line = vim.api.nvim_get_current_line()
		local selection_num = tonumber(line:match("%d+"))

		if not selection_num or selection_num < 1 or selection_num > #options then
			vim.notify("Invalid selection", vim.log.levels.ERROR)
			return
		end

		safe_popup_close(state.selection_popup)
		create_man_popup(word_to_search, selection_num)
		state.current_page = options[selection_num].value
	end

	-- Selection popup keymaps
	vim.keymap.set("n", "<CR>", handle_selection, { silent = true, buffer = selection_popup.bufnr })
	vim.keymap.set("n", "q", function()
		safe_popup_close(state.selection_popup)
	end, { silent = true, buffer = selection_popup.bufnr })
	vim.keymap.set("n", "<ESC>", function()
		safe_popup_close(state.selection_popup)
	end, { silent = true, buffer = selection_popup.bufnr })

	-- Disable navigation keys in selection popup
	vim.keymap.set("n", "<C-o>", function() end, { silent = true, buffer = selection_popup.bufnr })
	vim.keymap.set("n", "K", function() end, { silent = true, buffer = selection_popup.bufnr })
	vim.keymap.set("n", "<C-]>", function() end, { silent = true, buffer = selection_popup.bufnr })

	vim.api.nvim_win_set_cursor(selection_popup.winid, { 1, 0 })
end

M.setup = function()
	vim.api.nvim_create_user_command("CPPMan", function(args)
		if args.args and #args.args > 1 then
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

	vim.keymap.set("n", "q", function()
		input:unmount()
	end, { silent = true, buffer = true })
	vim.keymap.set("n", "<ESC>", function()
		input:unmount()
	end, { silent = true, buffer = true })
end

M.open_cppman_for = function(word_to_search)
	-- Clean up existing popups
	safe_popup_close(state.selection_popup)
	safe_popup_close(state.current_popup)

	local options = parse_cppman_options(word_to_search)

	if #options == 0 then
		create_man_popup(word_to_search)
		return
	end

	create_selection_popup(options, word_to_search)
end

return M
