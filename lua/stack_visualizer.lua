-- Stack Visualizer for Assembly Code
-- Advanced dynamic stack visualization with Multi-Variable Highlighting

local M = {}
local timer = nil
local source_buf = nil
local stack_buf = nil
local stack_win = nil

-- Configuration
local config = {
  refresh_rate = 5000, -- 5 seconds
}

-- Parse assembly file for stack information
local function parse_assembly(lines)
  local functions = {}
  local current_func = nil
  local line_map = {} -- Map line numbers to LIST of variables accessed
  
  for i, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    
    -- Detect function labels
    local func_name = trimmed:match("^([%w_]+):")
    if func_name and not func_name:match("^%.") then
      current_func = {
        name = func_name,
        stack_size = 0,
        variables = {},
        saved_regs = {},
        start_line = i,
        has_calls = false,
      }
      functions[func_name] = current_func
    end
    
    if current_func then
      current_func.end_line = i
      
      -- Stack allocation
      local sub_amt = trimmed:match("sub%s+rsp,%s*(%d+)")
      if sub_amt then
        current_func.stack_size = tonumber(sub_amt)
      end
      
      -- Track pushed registers
      local push_reg = trimmed:match("push%s+(%w+)")
      if push_reg then
        table.insert(current_func.saved_regs, push_reg)
      end
      
      -- Track calls
      if trimmed:match("call%s+") then
        current_func.has_calls = true
      end
      
      -- Find ALL rbp-relative accesses in the line
      -- We use gmatch to find multiple occurrences
      for offset in trimmed:gmatch("%[rbp%-(%d+)%]") do
        local off_num = tonumber(offset)
        
        -- Map this line to the offset (store as list)
        if not line_map[i] then line_map[i] = {} end
        table.insert(line_map[i], off_num)
        
        if not current_func.variables[off_num] then
          current_func.variables[off_num] = {
            offset = off_num,
            type = "unknown",
          }
        end
        
        local var = current_func.variables[off_num]
        
        -- Detect type (basic heuristic)
        if trimmed:match("mov%s+byte") then var.type = "byte"
        elseif trimmed:match("mov%s+word") then var.type = "word"
        elseif trimmed:match("mov%s+dword") then var.type = "dword"
        elseif trimmed:match("mov%s+qword") or trimmed:match("lea") then var.type = "qword"
        end
        
        -- Detect string operations
        if trimmed:match("lstrcpy") or trimmed:match("lstrcat") then
          var.type = "string"
        end
      end
    end
  end
  
  return functions, line_map
end

-- Calculate variable ranges
local function calculate_ranges(variables, total_stack)
  local sorted = {}
  for _, v in pairs(variables) do
    table.insert(sorted, v)
  end
  table.sort(sorted, function(a, b) return a.offset < b.offset end)
  
  local ranges = {}
  for i, var in ipairs(sorted) do
    local next_offset = sorted[i + 1] and sorted[i + 1].offset or total_stack
    local actual_size = next_offset - var.offset
    
    table.insert(ranges, {
      offset = var.offset,
      size = actual_size,
      vtype = var.type,
    })
  end
  
  return ranges
end

-- Get color based on size
local function get_color(size, is_active)
  if is_active then return "Search" end
  if size >= 1024 then return "ErrorMsg"
  elseif size >= 512 then return "WarningMsg"
  elseif size >= 64 then return "String"
  elseif size >= 8 then return "Number"
  else return "Comment" end
end

-- Format bytes
local function format_bytes(bytes)
  if bytes >= 1024 then return string.format("%.1fK", bytes / 1024)
  else return tostring(bytes) .. "B" end
end

-- Calculate cell height
local function calc_height(size, max_size)
  if size == 0 then return 2 end
  local ratio = size / max_size
  local height = math.floor(2 + ratio * 8)
  return math.max(2, math.min(height, 10))
end

-- Generate stack visualization lines
local function generate_lines(functions, width, active_offsets)
  local lines = {}
  local highlights = {}
  local w = math.max(40, width)
  
  -- Helper to check if offset is active
  local function is_active_offset(offset)
    if not active_offsets then return false end
    for _, off in ipairs(active_offsets) do
      if off == offset then return true end
    end
    return false
  end
  
  for fname, func in pairs(functions) do
    if func.stack_size == 0 then goto continue end
    
    local ranges = calculate_ranges(func.variables, func.stack_size)
    if #ranges == 0 then goto continue end
    
    -- Find max size for scaling
    local max_size = 0
    for _, r in ipairs(ranges) do
      if r.size > max_size then max_size = r.size end
    end
    
    -- Function Header
    local header = string.format(" %s • %s ", fname, format_bytes(func.stack_size))
    local pad = math.floor((w - #header) / 2)
    
    table.insert(lines, string.rep("─", w))
    table.insert(lines, string.rep(" ", pad) .. header)
    table.insert(highlights, {line = #lines, col = 0, hl = "Function"})
    
    -- Alignment Check
    local total_pushed = 8 + (#func.saved_regs * 8) + func.stack_size
    if total_pushed % 16 ~= 0 then
      local warning = " ⚠ STACK MISALIGNED (Not 16-byte aligned) "
      local pad_w = math.floor((w - #warning) / 2)
      table.insert(lines, string.rep(" ", pad_w) .. warning)
      table.insert(highlights, {line = #lines, col = 0, hl = "ErrorMsg"})
    end
    
    -- Return Address
    table.insert(lines, string.rep("─", w))
    table.insert(lines, " Return Address (8B)")
    table.insert(highlights, {line = #lines, col = 0, hl = "Comment"})
    
    -- Saved Registers
    if #func.saved_regs > 0 then
      table.insert(lines, string.rep("─", w))
      for _, reg in ipairs(func.saved_regs) do
        local reg_info = string.format(" Saved %s (8B)", reg)
        table.insert(lines, reg_info)
        table.insert(highlights, {line = #lines, col = 0, hl = "Special"})
      end
    end
    
    -- RBP Marker
    table.insert(lines, string.rep("─", w))
    table.insert(lines, " RBP (Base Pointer)")
    table.insert(highlights, {line = #lines, col = 0, hl = "Keyword"})
    
    -- Stack Variables
    for i, r in ipairs(ranges) do
      table.insert(lines, string.rep("─", w))
      
      local is_active = is_active_offset(r.offset)
      local height = calc_height(r.size, max_size)
      local offset_str = string.format("[rbp-%d]", r.offset)
      local size_str = format_bytes(r.size)
      local type_str = r.vtype ~= "unknown" and r.vtype or ""
      
      -- Build info lines
      local info_lines = {}
      table.insert(info_lines, string.format("%s • %s", offset_str, size_str))
      if type_str ~= "" then table.insert(info_lines, type_str) end
      if is_active then table.insert(info_lines, "◄ CURRENTLY ACCESSING") end
      
      -- Render cell
      local start_line = math.floor((height - #info_lines) / 2)
      for h = 1, height do
        local info_idx = h - start_line
        local content = ""
        if info_idx >= 1 and info_idx <= #info_lines then
          content = info_lines[info_idx]
        end
        
        local pad_left = math.floor((w - #content) / 2)
        local line = string.rep(" ", pad_left) .. content
        table.insert(lines, line)
        table.insert(highlights, {line = #lines, col = 0, hl = get_color(r.size, is_active)})
      end
    end
    
    -- RSP Marker
    table.insert(lines, string.rep("─", w))
    table.insert(lines, " RSP (Stack Pointer)")
    table.insert(highlights, {line = #lines, col = 0, hl = "Keyword"})
    
    table.insert(lines, string.rep("─", w))
    table.insert(lines, "")
    
    ::continue::
  end
  
  return lines, highlights
end

-- Refresh the visualization
function M.refresh()
  if not stack_buf or not vim.api.nvim_buf_is_valid(stack_buf) then return end
  if not source_buf or not vim.api.nvim_buf_is_valid(source_buf) then return end
  
  local width = 40
  if stack_win and vim.api.nvim_win_is_valid(stack_win) then
    width = vim.api.nvim_win_get_width(stack_win)
  end
  
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local functions, line_map = parse_assembly(lines)
  
  if vim.tbl_count(functions) == 0 then return end
  
  local source_win = vim.fn.bufwinnr(source_buf)
  local active_offsets = nil
  if source_win ~= -1 then
    local win_id = vim.fn.win_getid(source_win)
    local cursor_line = vim.api.nvim_win_get_cursor(win_id)[1]
    active_offsets = line_map[cursor_line] -- This is now a list or nil
  end
  
  local viz_lines, highlights = generate_lines(functions, width, active_offsets)
  
  vim.api.nvim_buf_set_option(stack_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(stack_buf, 0, -1, false, viz_lines)
  vim.api.nvim_buf_set_option(stack_buf, 'modifiable', false)
  
  local ns_id = vim.api.nvim_create_namespace('stack_viz')
  vim.api.nvim_buf_clear_namespace(stack_buf, ns_id, 0, -1)
  for _, hl in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(stack_buf, ns_id, hl.hl, hl.line - 1, 0, -1)
  end
end

-- Open or update visualization
function M.show()
  local current_buf = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(current_buf)
  
  if filename:match("%.asm$") or filename:match("%.s$") then
    source_buf = current_buf
  end
  
  if not source_buf then
    vim.notify("No assembly file selected", vim.log.levels.WARN)
    return
  end
  
  if not stack_win or not vim.api.nvim_win_is_valid(stack_win) then
    vim.cmd('vsplit')
    stack_win = vim.api.nvim_get_current_win()
    
    if not stack_buf or not vim.api.nvim_buf_is_valid(stack_buf) then
      stack_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(stack_buf, 'buftype', 'nofile')
      vim.api.nvim_buf_set_option(stack_buf, 'bufhidden', 'hide')
      vim.api.nvim_buf_set_option(stack_buf, 'swapfile', false)
      vim.api.nvim_buf_set_name(stack_buf, 'Stack Visualizer')
      
      vim.api.nvim_buf_set_keymap(stack_buf, 'n', 'q', ':q<CR>', {noremap = true, silent = true})
    end
    
    vim.api.nvim_win_set_buf(stack_win, stack_buf)
    vim.api.nvim_win_set_option(stack_win, 'number', false)
    vim.api.nvim_win_set_option(stack_win, 'relativenumber', false)
    vim.api.nvim_win_set_option(stack_win, 'wrap', false)
    vim.api.nvim_win_set_width(stack_win, 50)
    
    vim.api.nvim_create_autocmd("WinResized", {
      buffer = stack_buf,
      callback = function() M.refresh() end,
    })
    
    vim.api.nvim_create_autocmd({"CursorMoved", "CursorMovedI"}, {
      buffer = source_buf,
      callback = function() M.refresh() end,
    })
  end
  
  M.refresh()
end

-- Auto-reload
function M.start_auto_reload()
  if timer then timer:stop() end
  timer = vim.loop.new_timer()
  timer:start(0, config.refresh_rate, vim.schedule_wrap(function()
    if stack_win and vim.api.nvim_win_is_valid(stack_win) then
      M.refresh()
    end
  end))
end

function M.stop_auto_reload()
  if timer then timer:stop() timer = nil end
end

return M
