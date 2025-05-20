local M = {}

local PRIORITY = (vim.hl or vim.highlight).priorities.user

-- Configuration with defaults
local CONFIG = {
    highlights = {
        added = 'DiffWatchAdd',         -- Added lines
        changed = 'DiffWatchChange',    -- Changed lines
        removed = 'DiffWatchDelete',    -- Removed lines
        modified = "DiffWatchModified", -- Modifed lines
        hint = 'DiffWatchHint',         -- Hint text
    },
    mappings = {
        ours = "<leader>co",
        theirs = "<leader>ca",
        both = "<leader>cu",
        none = "<leader>cn",
    },
    hint_position = 'eol_right_align',
}

-- Namespace for our extmarks
local NAMESPACE = vim.api.nvim_create_namespace('DiffWatch')

-- Add a new namespace for hint marks
local HINT_NAMESPACE = vim.api.nvim_create_namespace('DiffWatchHint')

-- Augroup for our autocommands

local augroup = vim.api.nvim_create_augroup("DiffWatch", { clear = true })

-- State tracking
local state = {
    original_lines = nil,
    changes = {},
    watching = false
}

--- Setup highlight groups
local function setup_highlights()
    local hlDiffAdd = vim.api.nvim_get_hl(0, { name = "DiffAdd" })
    local hlDiffChange = vim.api.nvim_get_hl(0, { name = "DiffChange" })
    vim.api.nvim_set_hl(0, "DiffWatchAdd", { bg = hlDiffAdd.bg })
    vim.api.nvim_set_hl(0, "DiffWatchChange", { bg = hlDiffChange.bg })
    vim.api.nvim_set_hl(0, "DiffWatchModified", { link = "DiffModified" })
    vim.api.nvim_set_hl(0, "DiffWatchDelete", { link = "DiffDelete" })
    vim.api.nvim_set_hl(0, "DiffWatchHint", { link = "DiagnosticHint" })
end

-- Add this helper function to check if cursor is in a change
---@return table|nil change The change the cursor is in, or nil if not in a change
---@return integer|nil start_line The first line of the change (1-based)
---@return integer|nil end_line The last line of the change (1-based)
local function get_current_change()
    if not state.changes or #state.changes == 0 then
        return nil, nil, nil
    end

    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor_pos[1] -- 1-based line number

    for _, change in ipairs(state.changes) do
        local change_start = change.lnum + 1 -- convert to 1-based
        local change_end = change_start

        if change.type == 'add' or change.type == 'change' then
            change_end = change_start + #change.current_lines - 1
        end

        -- For deletions, the change is exactly at change_start
        if (change.type == 'del' and current_line == change_start) or
            (change.type ~= 'del' and current_line >= change_start and current_line <= change_end) then
            return change, change_start, change_end
        end
    end

    return nil, nil, nil
end

local function find_previous_change(start_line)
    if not state.changes or #state.changes == 0 then
        return nil
    end

    -- Sort changes by line number descending
    local sorted_changes = {}
    for _, change in ipairs(state.changes) do
        table.insert(sorted_changes, change)
    end
    table.sort(sorted_changes, function(a, b)
        return a.lnum > b.lnum
    end)

    -- Find the first change above start_line
    for _, change in ipairs(sorted_changes) do
        local change_start = change.lnum + 1
        if change_start < start_line then
            return change_start
        end
    end

    return sorted_changes[1].lnum + 1
end

local function find_next_change(start_line)
    if not state.changes or #state.changes == 0 then
        return nil
    end

    -- Sort changes by line number ascending
    local sorted_changes = {}
    for _, change in ipairs(state.changes) do
        table.insert(sorted_changes, change)
    end
    table.sort(sorted_changes, function(a, b)
        return a.lnum < b.lnum
    end)

    -- Find the first change below start_line
    for _, change in ipairs(sorted_changes) do
        local change_start = change.lnum + 1
        if change_start > start_line then
            return change_start
        end
    end

    return sorted_changes[1].lnum + 1
end

-- Add this function to show/hide hints based on cursor position
local function update_cursor_hint()
    -- Clear previous hints
    vim.api.nvim_buf_clear_namespace(0, HINT_NAMESPACE, 0, -1)

    if not state.watching or not state.changes or #state.changes == 0 then
        return
    end

    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local current_line = cursor_pos[1] -- 1-based line number

    -- Check if cursor is in any change region
    for _, change in ipairs(state.changes) do
        local in_change = false

        if change.type == 'add' or change.type == 'change' then
            local start_line = change.lnum + 1 -- convert to 1-based
            local end_line = start_line + #change.current_lines - 1
            in_change = current_line >= start_line and current_line <= end_line
        elseif change.type == 'del' then
            -- For deletions, we consider the line where the deletion occurred
            in_change = current_line == change.lnum + 1
        end

        if in_change then
            -- Create hint text based on mappings
            local hint_text = string.format(
                "%s:ours|%s:theirs|%s:both|%s:none",
                CONFIG.mappings.ours,
                CONFIG.mappings.theirs,
                CONFIG.mappings.both,
                CONFIG.mappings.none
            )

            -- Position the hint
            local opts = {
                virt_text = { { hint_text, CONFIG.highlights.hint } },
                virt_text_pos = CONFIG.hint_position,
                hl_mode = 'combine',
                priority = PRIORITY + 1, -- Make sure it's above other marks
            }

            -- Place the hint on the current line
            vim.api.nvim_buf_set_extmark(0, HINT_NAMESPACE, current_line - 1, 0, opts)
            break
        end
    end
end

--- Generate diff between current and original buffer states
--- TODO(yuukibarns): Better Diff
--- @return integer[][]
local function generate_diff()
    local current_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    return vim.diff( ---@type integer[][]
        table.concat(state.original_lines, '\n'),
        table.concat(current_lines, '\n'),
        {
            result_type = 'indices',
            algorithm = "minimal",
            ignore_blank_lines = true,
            ignore_whitespace_change_at_eol = true
        }
    )
end

--- Find and highlight all changes
local function highlight_changes()
    -- Clear previous highlights
    vim.api.nvim_buf_clear_namespace(0, NAMESPACE, 0, -1)

    local diff = generate_diff()
    state.changes = {}

    -- Get current window width
    local win_width = vim.api.nvim_win_get_width(0)

    -- Process diff hunks
    for _, hunk in ipairs(diff) do
        local orig_start, orig_count, curr_start, curr_count =
            hunk[1], hunk[2], hunk[3], hunk[4]

        -- Handle additions (present in current but not original)
        if orig_count == 0 and curr_count > 0 then
            for i = curr_start, curr_start + curr_count - 1 do
                vim.api.nvim_buf_set_extmark(0, NAMESPACE, i - 1, 0, {
                    line_hl_group = CONFIG.highlights.added,
                    hl_mode = "combine",
                    end_row = i - 1,
                    priority = PRIORITY,
                })
            end
            table.insert(state.changes, {
                type = 'add',
                lnum = curr_start - 1,
                current_lines = vim.api.nvim_buf_get_lines(0, curr_start - 1, curr_start + curr_count - 1, false)
            })
            -- Handle deletions (present in original but not current)
        elseif curr_count == 0 and orig_count > 0 then
            local del_lines = {}
            for i = orig_start, orig_start + orig_count - 1 do
                table.insert(del_lines, state.original_lines[i])
            end
            table.insert(state.changes, {
                type = 'del',
                lnum = curr_start - 1,
                original_lines = del_lines
            })

            local del_lines_with_hi = {}
            local is_empty_lines = true

            for i = orig_start, orig_start + orig_count - 1 do
                if not state.original_lines[i]:match("^%s*$") then
                    is_empty_lines = false
                end
            end

            if not is_empty_lines then
                for i = orig_start, orig_start + orig_count - 1 do
                    local line = state.original_lines[i]
                    -- Calculate needed spaces
                    local line_width = vim.fn.strdisplaywidth(line)
                    local spaces_needed = math.max(0, win_width - line_width)
                    local padded_line = line .. string.rep(' ', spaces_needed)
                    table.insert(del_lines_with_hi, { { padded_line, CONFIG.highlights.removed } })
                end

                if curr_start == 0 then
                    vim.api.nvim_buf_set_extmark(0, NAMESPACE, 0, 0, {
                        virt_lines = del_lines_with_hi,
                    })
                else
                    vim.api.nvim_buf_set_extmark(0, NAMESPACE, curr_start - 1, 0, {
                        virt_lines = del_lines_with_hi,
                    })
                end
            end

            -- Handle changes (lines differ between versions)
        elseif orig_count > 0 and curr_count > 0 then
            -- Highlight changed lines
            for i = curr_start, curr_start + curr_count - 1 do
                vim.api.nvim_buf_set_extmark(0, NAMESPACE, i - 1, 0, {
                    line_hl_group = CONFIG.highlights.changed,
                    hl_mode = "combine",
                    end_row = i - 1,
                    priority = PRIORITY
                })
            end

            -- Show original lines as virtual text
            local orig_lines = {}
            for i = orig_start, orig_start + orig_count - 1 do
                table.insert(orig_lines, state.original_lines[i])
            end

            local orig_lines_with_hi = {}
            local is_empty_lines = true

            for i = orig_start, orig_start + orig_count - 1 do
                if not state.original_lines[i]:match("^%s*$") then
                    is_empty_lines = false
                end
            end

            if not is_empty_lines then
                for i = orig_start, orig_start + orig_count - 1 do
                    local line = state.original_lines[i]
                    -- Calculate needed spaces
                    local line_width = vim.fn.strdisplaywidth(line)
                    local spaces_needed = math.max(0, win_width - line_width)
                    local padded_line = line .. string.rep(' ', spaces_needed)
                    table.insert(orig_lines_with_hi, { { padded_line, CONFIG.highlights.modified } })
                end

                vim.api.nvim_buf_set_extmark(0, NAMESPACE, curr_start + curr_count - 2, 0, {
                    virt_lines = orig_lines_with_hi,
                })
            end

            table.insert(state.changes, {
                type = 'change',
                lnum = curr_start - 1,
                current_lines = vim.api.nvim_buf_get_lines(0, curr_start - 1, curr_start + curr_count - 1, false),
                original_lines = orig_lines
            })
        end
    end
end

function M.accept_theirs()
    if not state.watching or not state.original_lines then
        vim.api.nvim_echo({ { 'Not currently watching for changes', 'WarningMsg' } }, false, {})
        return
    end

    local changed_line, start_line = get_current_change()

    if not changed_line then
        vim.api.nvim_echo({ { 'Cursor is not on a changed line', 'WarningMsg' } }, false, {})
        return
    end

    -- Update the original_lines to match current state
    if changed_line.type == 'add' then
        -- For additions, insert the new lines into original
        for i, line in ipairs(changed_line.current_lines) do
            table.insert(state.original_lines, changed_line.lnum + i, line)
        end
    elseif changed_line.type == 'change' then
        -- First remove the original lines
        local original_start = changed_line.lnum + 1
        local original_end = original_start + #changed_line.original_lines - 1
        for _ = original_start, original_end do
            table.remove(state.original_lines, original_start)
        end

        -- Then insert the current lines
        for i, line in ipairs(changed_line.current_lines) do
            table.insert(state.original_lines, changed_line.lnum + i, line)
        end
    elseif changed_line.type == 'del' then
        local original_start = changed_line.lnum + 2
        local original_end = original_start + #changed_line.original_lines - 1
        for _ = original_start, original_end do
            table.remove(state.original_lines, original_start)
        end
    end

    -- Update highlights to reflect the new state
    highlight_changes()
    update_cursor_hint()
    vim.api.nvim_echo({ { 'Accepted current changes as new original', 'MoreMsg' } }, false, {})
end

function M.restore_ours()
    if not state.watching or not state.original_lines then
        vim.api.nvim_echo({ { 'Not currently watching for changes', 'WarningMsg' } }, false, {})
        return
    end

    local changed_line, start_line = get_current_change()

    if not changed_line then
        vim.api.nvim_echo({ { 'Cursor is not on a changed line', 'WarningMsg' } }, false, {})
        return
    end

    -- Update the current buffer to match original_lines
    if changed_line.type == 'add' then
        -- For additions, remove the added lines
        vim.api.nvim_buf_set_lines(0, changed_line.lnum, changed_line.lnum + #changed_line.current_lines, false, {})
    elseif changed_line.type == 'change' then
        -- First remove the current lines
        local current_start = changed_line.lnum
        local current_end = current_start + #changed_line.current_lines
        vim.api.nvim_buf_set_lines(0, current_start, current_end, false, {})

        -- Restore the original lines
        vim.api.nvim_buf_set_lines(0, changed_line.lnum, changed_line.lnum, false, changed_line.original_lines)
    elseif changed_line.type == 'del' then
        -- For deletions, restore the deleted lines
        vim.api.nvim_buf_set_lines(0, changed_line.lnum + 1, changed_line.lnum + 1, false, changed_line.original_lines)
    end

    -- Set cursor to the start line of the current change
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local current_col = cursor_pos[2]

    -- If current_col out of range, neovim will automatically set cursor at the end of line
    vim.api.nvim_win_set_cursor(0, { start_line, current_col })

    -- Update highlights to reflect the new state
    highlight_changes()
    update_cursor_hint()
    vim.api.nvim_echo({ { 'Restored original content', 'MoreMsg' } }, false, {})
end

function M.use_both()
    if not state.watching or not state.original_lines then
        vim.api.nvim_echo({ { 'Not currently watching for changes', 'WarningMsg' } }, false, {})
        return
    end

    local changed_line, start_line = get_current_change()

    if not changed_line then
        vim.api.nvim_echo({ { 'Cursor is not on a changed line', 'WarningMsg' } }, false, {})
        return
    end

    -- Update the current buffer to match original_lines
    if changed_line.type == 'add' then
        -- For additions, insert the new lines into original
        for i, line in ipairs(changed_line.current_lines) do
            table.insert(state.original_lines, changed_line.lnum + i, line)
        end
    elseif changed_line.type == 'change' then
        -- First insert the new lines into original
        for i, line in ipairs(changed_line.current_lines) do
            table.insert(state.original_lines, changed_line.lnum + i, line)
        end

        -- Then original lines become "Deleted".
        -- Restore them.
        vim.api.nvim_buf_set_lines(0, changed_line.lnum + #changed_line.current_lines,
            changed_line.lnum + #changed_line.current_lines, false, changed_line.original_lines)
    elseif changed_line.type == 'del' then
        -- For deletions, restore the deleted lines
        vim.api.nvim_buf_set_lines(0, changed_line.lnum + 1, changed_line.lnum + 1, false, changed_line.original_lines)
    end

    -- Update highlights to reflect the new state
    highlight_changes()
    update_cursor_hint()
    vim.api.nvim_echo({ { 'Use Both', 'MoreMsg' } }, false, {})
end

function M.use_none()
    if not state.watching or not state.original_lines then
        vim.api.nvim_echo({ { 'Not currently watching for changes', 'WarningMsg' } }, false, {})
        return
    end

    local changed_line, start_line = get_current_change()

    if not changed_line then
        vim.api.nvim_echo({ { 'Cursor is not on a changed line', 'WarningMsg' } }, false, {})
        return
    end

    -- Update the current buffer to match original_lines
    if changed_line.type == 'add' then
        -- For additions, remove the added lines
        vim.api.nvim_buf_set_lines(0, changed_line.lnum, changed_line.lnum + #changed_line.current_lines, false, {})
    elseif changed_line.type == 'change' then
        -- First remove the current lines
        local current_start = changed_line.lnum
        local current_end = current_start + #changed_line.current_lines
        vim.api.nvim_buf_set_lines(0, current_start, current_end, false, {})

        -- Then remove the original lines
        local original_start = changed_line.lnum + 1
        local original_end = original_start + #changed_line.original_lines - 1
        for _ = original_start, original_end do
            table.remove(state.original_lines, original_start)
        end
    elseif changed_line.type == 'del' then
        local original_start = changed_line.lnum + 3
        local original_end = original_start + #changed_line.original_lines - 1
        for _ = original_start, original_end do
            table.remove(state.original_lines, original_start)
        end
    end

    -- Set cursor to the start line of the current change
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local current_col = cursor_pos[2]

    -- If current_col out of range, neovim will automatically set cursor at the end of line
    vim.api.nvim_win_set_cursor(0, { start_line, current_col })

    -- Update highlights to reflect the new state
    highlight_changes()
    update_cursor_hint()
    vim.api.nvim_echo({ { 'Use Both', 'MoreMsg' } }, false, {})
end

function M.goto_prev_change()
    local change, change_start, _ = get_current_change()
    local search_from = change and (change_start - 1) or vim.api.nvim_win_get_cursor(0)[1]

    local prev_change_line = find_previous_change(search_from)
    if prev_change_line then
        -- Set cursor to the start line of the current change
        local cursor_pos = vim.api.nvim_win_get_cursor(0)
        local current_col = cursor_pos[2]

        -- If current_col out of range, neovim will automatically set cursor at the end of line
        vim.api.nvim_win_set_cursor(0, { prev_change_line, current_col })
        update_cursor_hint()
    else
        vim.api.nvim_echo({ { 'No changes found', 'WarningMsg' } }, false, {})
    end
end

function M.goto_next_change()
    local change, _, change_end = get_current_change()
    local search_from = change and (change_end + 1) or vim.api.nvim_win_get_cursor(0)[1]

    local next_change_line = find_next_change(search_from)
    if next_change_line then
        -- Set cursor to the start line of the current change
        local cursor_pos = vim.api.nvim_win_get_cursor(0)
        local current_col = cursor_pos[2]

        -- If current_col out of range, neovim will automatically set cursor at the end of line
        vim.api.nvim_win_set_cursor(0, { next_change_line, current_col })
        update_cursor_hint()
    else
        vim.api.nvim_echo({ { 'No changes found', 'WarningMsg' } }, false, {})
    end
end

--- Start watching for changes
function M.start_watching()
    local bufnr = vim.api.nvim_get_current_buf()
    state.original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    state.watching = true

    -- Highlight initial changes
    highlight_changes()

    -- Set up autocommand to update on changes
    vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = augroup,
        buffer = bufnr,
        callback = function()
            highlight_changes()
            update_cursor_hint()
        end
    })

    -- Add cursor movement tracking
    vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
        group = augroup,
        buffer = bufnr,
        callback = update_cursor_hint
    })

    vim.api.nvim_echo({ { 'Now watching for changes', 'MoreMsg' } }, false, {})
end

-- Modify the stop_watching function to clear cursor tracking
-- Stop watching and clear highlights
function M.stop_watching()
    state.watching = false
    local bufnr = vim.api.nvim_get_current_buf()

    -- Clear autocommands
    vim.api.nvim_clear_autocmds({
        group = augroup,
        buffer = bufnr,
    })

    -- Clear highlights and hints
    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, HINT_NAMESPACE, 0, -1)

    -- Reset state
    state.original_lines = nil
    state.changes = {}

    vim.api.nvim_echo({ { 'Stopped watching for changes', 'MoreMsg' } }, false, {})
end

--- Toggle watching state
function M.toggle_watching()
    if state.watching then
        M.stop_watching()
    else
        M.start_watching()
    end
end

--- Reset watching (capture new original state)
function M.reset_watching()
    if not state.watching then return end
    M.stop_watching()
    M.start_watching()
end

--- Setup key mappings
local function setup_mappings()
    for cmd, key in pairs(CONFIG.mappings) do
        if cmd == 'ours' then
            vim.keymap.set('n', key, M.restore_ours, { noremap = true, silent = true, desc = "Restore Original" })
        elseif cmd == 'theirs' then
            vim.keymap.set('n', key, M.accept_theirs, { noremap = true, silent = true, desc = "Accept New" })
        elseif cmd == "both" then
            vim.keymap.set('n', key, M.use_both, { noremap = true, silent = true, desc = "Use Both" })
        elseif cmd == "none" then
            vim.keymap.set('n', key, M.use_none, { noremap = true, silent = true, desc = "Use None" })
        end
    end
end

--- Setup the command
function M.setup(user_config)
    -- Merge user config with defaults
    if user_config then
        CONFIG = vim.tbl_deep_extend('force', CONFIG, user_config)
    end

    -- Initialize
    setup_highlights()
    setup_mappings()

    -- Create commands
    vim.api.nvim_create_user_command('DiffWatchToggle', M.toggle_watching, {
        desc = 'Toggle watching for changes in current buffer'
    })

    vim.api.nvim_create_user_command('DiffWatchReset', M.reset_watching, {
        desc = 'Reset watching with current buffer as new original'
    })

    vim.api.nvim_create_user_command('DiffWatchPrev', M.goto_prev_change, {
        desc = 'Go to previous change'
    })

    vim.api.nvim_create_user_command('DiffWatchNext', M.goto_next_change, {
        desc = 'Go to next change'
    })
end

return M
