local Input = require("nui.input")
local event = require("nui.utils.autocmd").event
local Popup = require("nui.popup")

local M = {}

local state = {
	stack = {},
	current_page = nil,
	current_popup = nil,
	selection_popup = nil,
	cache = {}, -- Added cache for cppman results
}

-- Utility functions
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

local function cleanup_popups()
	safe_popup_close(state.selection_popup)
	safe_popup_close(state.current_popup)
end

-- Use vim.system for async command execution (Neovim 0.10+)
local function execute_cppman_command_async(selection, selection_number, callback)
	-- Check if result is cached
	local cache_key = selection .. (selection_number and tostring(selection_number) or "")
	if state.cache[cache_key] then
		callback(state.cache[cache_key])
		return
	end

	local cmd = { "cppman", selection }
	if selection_number then
		cmd = { "sh", "-c", string.format("echo %d | cppman '%s' 2>&1", selection_number, selection) }
	end

	vim.system(cmd, { text = true }, function(obj)
		if obj.code ~= 0 then
			callback({ "Error running cppman: " .. (obj.stderr or "unknown error") })
			return
		end

		local result = obj.stdout
		local lines = {}
		for line in result:gmatch("[^\r\n]+") do
			if line:find("Please enter the selection:") then
				lines = {}
			else
				table.insert(lines, line)
			end
		end

		-- Cache the result
		if #lines > 0 then
			state.cache[cache_key] = lines
		end

		callback(#lines > 0 and lines or { "No output from cppman" })
	end)
end

-- Buffer configuration functions
local function configure_buffer(bufnr, winid, filetype, is_modifiable)
	local bo = vim.bo[bufnr]
	bo.buftype = "nofile"
	bo.bufhidden = "wipe"
	bo.swapfile = false
	bo.modifiable = is_modifiable
	bo.readonly = not is_modifiable
	bo.filetype = filetype

	-- Enable wrapping for dynamic resizing
	vim.api.nvim_win_set_option(winid, "wrap", true)
	vim.api.nvim_win_set_option(winid, "linebreak", true)
	vim.api.nvim_win_set_option(winid, "signcolumn", "no")
	vim.api.nvim_win_set_option(winid, "number", false)
	vim.api.nvim_win_set_option(winid, "relativenumber", false)
end

local function configure_cppman_buffer(bufnr, winid)
	configure_buffer(bufnr, winid, "cppman", false)
	vim.bo[bufnr].keywordprg = "cppman"
end

local function configure_selection_buffer(bufnr, winid)
	configure_buffer(bufnr, winid, "cppman-select", false)
end

-- Content population functions
local function populate_man_page_async(bufnr, winid, selection, selection_number)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Loading..." })

	execute_cppman_command_async(selection, selection_number, function(lines)
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.bo[bufnr].modifiable = true
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
				configure_cppman_buffer(bufnr, winid)
			end
		end)
	end)
end

local function populate_selection_options(bufnr, options, word_to_search)
	local lines = {}
	for _, opt in ipairs(options) do
		table.insert(lines, string.format("%2d. %s", opt.num, opt.text))
	end
	table.insert(lines, "")
	table.insert(lines, "Enter selection number (1-" .. #options .. "):")

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

-- Navigation functions
local function navigate_to_new_page()
	if state.current_page and state.current_popup then
		table.insert(state.stack, state.current_page)
	end
	state.current_page = vim.fn.expand("<cWORD>")
	M.open_cppman_for(state.current_page)
end

local function navigate_back()
	if #state.stack == 0 then
		return
	end
	state.current_page = table.remove(state.stack)
	M.open_cppman_for(state.current_page)
end

-- Option parsing with caching
local function parse_cppman_options_async(word_to_search, callback)
	-- Check cache first
	if state.cache["options_" .. word_to_search] then
		callback(state.cache["options_" .. word_to_search])
		return
	end

	vim.system({ "cppman", word_to_search }, { text = true }, function(obj)
		if obj.code ~= 0 then
			callback({})
			return
		end

		local result = obj.stdout
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

		-- Cache the options
		state.cache["options_" .. word_to_search] = options
		callback(options)
	end)
end

-- Popup creation functions
local function create_popup(options)
	local popup = Popup(options)
	popup:mount()
	return popup
end

local function setup_man_popup_keymaps(popup)
	local bufnr = popup.bufnr
	local opts = { silent = true, buffer = bufnr, nowait = true }

	vim.keymap.set("n", "q", function()
		safe_popup_close(popup)
	end, opts)
	vim.keymap.set("n", "<ESC>", function()
		safe_popup_close(popup)
	end, opts)
	vim.keymap.set("n", "K", navigate_to_new_page, opts)
	vim.keymap.set("n", "<C-]>", navigate_to_new_page, opts)
	vim.keymap.set("n", "<2-LeftMouse>", navigate_to_new_page, opts)
	vim.keymap.set("n", "<C-o>", navigate_back, opts)
	vim.keymap.set("n", "<RightMouse>", navigate_back, opts)
end

local function create_man_popup(selection, selection_number)
	local popup = create_popup({
		enter = true,
		focusable = true,
		border = { style = "double", text = { top = "[cppman]" } },
		position = "50%",
		size = { width = 80, height = "80%" },
	})

	state.current_popup = popup
	populate_man_page_async(popup.bufnr, popup.winid, selection, selection_number)
	setup_man_popup_keymaps(popup)

	return popup
end

local function setup_selection_popup_keymaps(popup, options, word_to_search)
	local bufnr = popup.bufnr
	local opts = { silent = true, buffer = bufnr }

	local function handle_selection()
		local line = vim.api.nvim_get_current_line()
		local selection_num = tonumber(line:match("%d+"))

		if not selection_num or selection_num < 1 or selection_num > #options then
			vim.notify("Invalid selection", vim.log.levels.ERROR)
			return
		end

		safe_popup_close(popup)
		create_man_popup(word_to_search, selection_num)
		state.current_page = options[selection_num].value
	end

	vim.keymap.set("n", "<CR>", handle_selection, opts)
	vim.keymap.set("n", "q", function()
		safe_popup_close(popup)
	end, opts)
	vim.keymap.set("n", "<ESC>", function()
		safe_popup_close(popup)
	end, opts)

	-- Disable navigation keys in selection popup
	vim.keymap.set("n", "<C-o>", function() end, opts)
	vim.keymap.set("n", "K", function() end, opts)
	vim.keymap.set("n", "<C-]>", function() end, opts)
end

local function create_selection_popup(options, word_to_search)
	local popup = create_popup({
		enter = true,
		focusable = true,
		border = { style = "double", text = { top = "[Select cppman entry]" } },
		position = "50%",
		size = { width = 80, height = math.min(20, #options + 2) },
	})

	state.selection_popup = popup
	populate_selection_options(popup.bufnr, options, word_to_search)
	configure_selection_buffer(popup.bufnr, popup.winid)

	vim.api.nvim_win_set_option(popup.winid, "cursorline", true)
	vim.api.nvim_win_set_option(popup.winid, "cursorlineopt", "line")
	setup_selection_popup_keymaps(popup, options, word_to_search)
	vim.api.nvim_win_set_cursor(popup.winid, { 1, 0 })

	return popup
end

-- Public API
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

	-- Set up input keymaps directly
	vim.keymap.set("n", "q", function()
		input:unmount()
	end, { silent = true, buffer = true })
	vim.keymap.set("n", "<ESC>", function()
		input:unmount()
	end, { silent = true, buffer = true })
end

M.open_cppman_for = function(word_to_search)
	cleanup_popups()

	parse_cppman_options_async(word_to_search, function(options)
		vim.schedule(function()
			if #options == 0 then
				create_man_popup(word_to_search)
			else
				create_selection_popup(options, word_to_search)
			end
		end)
	end)
end

return M
