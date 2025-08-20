local Input = require("nui.input")
local event = require("nui.utils.autocmd").event
local Popup = require("nui.popup")

local M = {}

local function tablelength(T)
	local count = 0
	for _ in pairs(T) do
		count = count + 1
	end
	return count
end

local stack = {}
local current_page = nil

local function get_cppman_options(word_to_search)
	-- Run cppman to get the list of options
	local handle = io.popen("cppman '" .. word_to_search .. "' 2>&1")
	local result = handle:read("*a")
	handle:close()

	-- Parse the output to extract options
	local options = {}
	for line in result:gmatch("[^\r\n]+") do
		if line:match("^%d+%.") then
			local num, desc = line:match("^(%d+)%.%s*(.*)")
			table.insert(options, {
				num = tonumber(num),
				text = desc,
				value = desc:match("^[^ ]+") or desc, -- Extract the first word as value
			})
		end
	end

	return options
end

local function show_man_page(manwidth, selection)
	vim.bo.ro = false
	vim.bo.ma = true

	vim.api.nvim_buf_set_lines(0, 0, -1, true, {})

	-- Show the selected man page
	local cmd = string.format([[ 0r! cppman --force-columns %d '%s' ]], manwidth, selection)
	vim.cmd(cmd)

	vim.cmd("0") -- Go to top of document

	-- Set window options for proper display
	vim.wo.wrap = false
	vim.wo.linebreak = true
	vim.wo.signcolumn = "no"
	vim.wo.number = false
	vim.wo.relativenumber = false

	vim.bo.ro = true
	vim.bo.ma = false
	vim.bo.mod = false
	vim.bo.keywordprg = "cppman"
	vim.bo.buftype = "nofile"
	vim.bo.filetype = "cppman"
end

local function loadNewPage()
	if current_page ~= nil then
		table.insert(stack, current_page)
	end

	current_page = vim.fn.expand("<cWORD>")

	local wininfo = vim.fn.getwininfo(vim.fn.win_getid())[1]
	local manwidth = wininfo.width - 4 -- Account for border characters

	show_man_page(manwidth, current_page)
end

local function backToPrevPage()
	if table.getn(stack) == 0 then
		return
	end

	current_page = table.remove(stack)

	local wininfo = vim.fn.getwininfo(vim.fn.win_getid())[1]
	local manwidth = wininfo.width - 4 -- Account for border characters

	show_man_page(manwidth, current_page)
end

M.setup = function()
	vim.api.nvim_create_user_command("CPPMan", function(args)
		if args.args ~= nil then
			if string.len(args.args) > 1 then
				M.open_cppman_for(args.args)
			else
				M.input()
			end
		else
			M.input()
		end
	end, { nargs = "?" })
end

M.input = function()
	local input = Input({
		position = "50%",
		size = {
			width = 20,
		},
		border = {
			style = "double",
			text = {
				top = "[Search cppman]",
				top_align = "center",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:Normal",
		},
	}, {
		prompt = "> ",
		default_value = "",
		on_close = function() end,
		on_submit = function(value)
			M.open_cppman_for(value)
		end,
	})

	-- mount/open the component
	input:mount()

	-- unmount component when cursor leaves buffer
	input:on(event.BufLeave, function()
		input:unmount()
	end)

	vim.keymap.set("n", "q", ":q!<cr>", { silent = true, buffer = true })
	vim.keymap.set("n", "<ESC>", ":q!<cr>", { silent = true, buffer = true })
end

-- Pops up a window containing the results of the search
M.open_cppman_for = function(word_to_search)
	local options = get_cppman_options(word_to_search)

	if #options == 0 then
		vim.notify("No cppman results found for: " .. word_to_search, vim.log.levels.WARN)
		return
	end

	-- Create a popup to show the selection options
	local selection_popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = "double",
			text = {
				top = "[Select cppman entry]",
				top_align = "center",
			},
		},
		position = "50%",
		size = {
			width = 80,
			height = math.min(20, #options + 2),
		},
	})

	-- mount/open the component
	selection_popup:mount()

	-- Set window options for better display
	vim.api.nvim_win_set_option(selection_popup.winid, "wrap", false)
	vim.api.nvim_win_set_option(selection_popup.winid, "number", false)
	vim.api.nvim_win_set_option(selection_popup.winid, "relativenumber", false)
	vim.api.nvim_win_set_option(selection_popup.winid, "signcolumn", "no")

	-- Prepare the selection content
	local lines = {}
	for _, option in ipairs(options) do
		table.insert(lines, string.format("%2d. %s", option.num, option.text))
	end
	table.insert(lines, "")
	table.insert(lines, "Enter selection number (1-" .. #options .. "):")

	-- Set the content
	vim.api.nvim_buf_set_lines(selection_popup.bufnr, 0, -1, false, lines)

	-- Set up keymaps for selection
	local function handle_selection()
		local line = vim.api.nvim_get_current_line()
		local selection_num = tonumber(line:match("%d+"))

		if selection_num and selection_num >= 1 and selection_num <= #options then
			local selected_option = options[selection_num]

			-- Close the selection popup
			selection_popup:unmount()

			-- Open the man page popup
			local popup = Popup({
				enter = true,
				focusable = true,
				border = {
					style = "double",
					text = {
						top = "[cppman]",
						top_align = "center",
					},
				},
				position = "50%",
				size = {
					width = "90%",
					height = "80%",
				},
			})

			-- mount/open the component
			popup:mount()

			-- Set window options for better display
			vim.api.nvim_win_set_option(popup.winid, "wrap", false)
			vim.api.nvim_win_set_option(popup.winid, "number", false)
			vim.api.nvim_win_set_option(popup.winid, "relativenumber", false)
			vim.api.nvim_win_set_option(popup.winid, "signcolumn", "no")

			-- Calculate width accounting for borders (2 characters each side)
			local wininfo = vim.fn.getwininfo(popup.winid)[1]
			local manwidth = wininfo.width - 4 -- Account for border characters

			show_man_page(manwidth, selected_option.value)
			current_page = selected_option.value

			-- unmount component when cursor leaves buffer
			popup:on(event.BufLeave, function()
				popup:unmount()
			end)

			vim.keymap.set("n", "q", ":q!<cr>", { silent = true, buffer = true, nowait = true })

			vim.keymap.set("n", "K", loadNewPage, { silent = true, buffer = true })
			vim.keymap.set("n", "<C-]>", loadNewPage, { silent = true, buffer = true })
			vim.keymap.set("n", "<2-LeftMouse>", loadNewPage, { silent = true, buffer = true })

			vim.keymap.set("n", "<C-T>", backToPrevPage, { silent = true, buffer = true })
			vim.keymap.set("n", "<RightMouse>", backToPrevPage, { silent = true, buffer = true })
		else
			vim.notify("Invalid selection. Please enter a number between 1 and " .. #options, vim.log.levels.ERROR)
		end
	end

	-- Set up keymaps for the selection popup
	vim.keymap.set("n", "<CR>", handle_selection, { silent = true, buffer = selection_popup.bufnr })
	vim.keymap.set("n", "q", function()
		selection_popup:unmount()
	end, { silent = true, buffer = selection_popup.bufnr })
	vim.keymap.set("n", "<ESC>", function()
		selection_popup:unmount()
	end, { silent = true, buffer = selection_popup.bufnr })

	-- Move cursor to the input line
	vim.api.nvim_win_set_cursor(selection_popup.winid, { #lines, 0 })
end

return M
