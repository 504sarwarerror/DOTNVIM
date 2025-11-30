-- Stack Visualizer for Assembly Code
-- Advanced dynamic stack visualization (Horizontal Layout)

local M = {}
local timer = nil
local source_buf = nil
local stack_buf = nil
local stack_win = nil

-- Parse assembly file for stack information
local function parse_assembly(lines)
  local functions = {}
  local current_func = nil
  
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
      }
      functions[func_name] = current_func
    end
    
    if current_func then
      -- Stack allocation
      local sub_amt = trimmed:match("sub%s+rsp,%s*(%d+)")
      if sub_amt then
        current_func.stack_size = tonumber(sub_amt)
      end
      
      -- Track pushed registers (saved state)
      local push_reg = trimmed:match("push%s+(%w+)")
      if push_reg then
        table.insert(current_func.saved_regs, push_reg)
      end
      
      -- Find rbp-relative accesses
      local offset = trimmed:match("%[rbp%-(%d+)%]")
      if offset then
        local off_num = tonumber(offset)
        if not current_func.variables[off_num] then
          current_func.variables[off_num] = {
            offset = off_num,
            type = "unknown",
            usage = {},
          }
        end
        
        local var = current_func.variables[off_num]
        
        -- Detect type
        if trimmed:match("mov%s+byte") then var.type = "byte"
        elseif trimmed:match("mov%s+word") then var.type = "word"
        elseif trimmed:match("mov%s+dword") then var.type = "dword"
        elseif trimmed:match("mov%s+qword") or trimmed:match("lea") then var.type = "qword"
        end
        
        -- Track usage
        local func_call = trimmed:match("call%s+([%w_]+)")
        if func_call and not vim.tbl_contains(var.usage, func_call) then
          table.insert(var.usage, func_call)
        end
        
        -- Detect string operations
        if trimmed:match("lstrcpy") or trimmed:match("lstrcat") then
          var.type = "string"
        end
      end
    end
  end
  
  return functions
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
      usage = var.usage,
    })
  end
  
  return ranges
end

-- Get color based on size
local function get_color(size)
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
local function generate_lines(functions, width)
  local lines = {}
  local highlights = {}
  local w = math.max(40, width)
  
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
    
    -- Saved Registers (Pushed)
    if #func.saved_regs > 0 then
      table.insert(lines, string.rep("─", w))
      for _, reg in ipairs(func.saved_regs) do
        local reg_info = string.format(" Saved %s", reg)
        table.insert(lines, reg_info)
        table.insert(highlights, {line = #lines, col = 0, hl = "Special"})
      end
    end
    
    -- RBP Marker
    table.insert(lines, string.rep("─", w))
    local rbp_info = " RBP (Base Pointer)"
    table.insert(lines, rbp_info)
    table.insert(highlights, {line = #lines, col = 0, hl = "Keyword"})
    
    -- Stack Variables
    for i, r in ipairs(ranges) do
      table.insert(lines, string.rep("─", w))
      
      local height = calc_height(r.size, max_size)
      local offset_str = string.format("[rbp-%d]", r.offset)
      local size_str = format_bytes(r.size)
      local type_str = r.vtype ~= "unknown" and r.vtype or ""
      
      -- Build info lines
      local info_lines = {}
      table.insert(info_lines, string.format("%s • %s", offset_str, size_str))
      if type_str ~= "" then table.insert(info_lines, type_str) end
      if #r.usage > 0 then
        local usage = "→ " .. table.concat(r.usage, ", ")
        if #usage > w - 4 then usage = usage:sub(1, w - 7) .. "..." end
        table.insert(info_lines, usage)
      end
      
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
        table.insert(highlights, {line = #lines, col = 0, hl = get_color(r.size)})
      end
    end
    
    -- RSP Marker
    table.insert(lines, string.rep("─", w))
    local rsp_info = " RSP (Stack Pointer)"
    table.insert(lines, rsp_info)
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
  
  -- Get window width
  local width = 40
  if stack_win and vim.api.nvim_win_is_valid(stack_win) then
    width = vim.api.nvim_win_get_width(stack_win)
  end
  
  -- Parse source
  local lines = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local functions = parse_assembly(lines)
  
  if vim.tbl_count(functions) == 0 then return end
  
  -- Generate
  local viz_lines, highlights = generate_lines(functions, width)
  
  -- Update buffer
  vim.api.nvim_buf_set_option(stack_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(stack_buf, 0, -1, false, viz_lines)
  vim.api.nvim_buf_set_option(stack_buf, 'modifiable', false)
  
  -- Highlight
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
  
  -- If current buffer is assembly, set as source
  if filename:match("%.asm$") or filename:match("%.s$") then
    source_buf = current_buf
  end
  
  if not source_buf then
    vim.notify("No assembly file selected", vim.log.levels.WARN)
    return
  end
  
  -- Check/Create Window
  if not stack_win or not vim.api.nvim_win_is_valid(stack_win) then
    -- Create new split
    vim.cmd('vsplit')
    stack_win = vim.api.nvim_get_current_win()
    
    -- Create buffer if needed
    if not stack_buf or not vim.api.nvim_buf_is_valid(stack_buf) then
      stack_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(stack_buf, 'buftype', 'nofile')
      vim.api.nvim_buf_set_option(stack_buf, 'bufhidden', 'hide')
      vim.api.nvim_buf_set_option(stack_buf, 'swapfile', false)
      vim.api.nvim_buf_set_name(stack_buf, 'Stack Visualizer')
      
      -- Keybindings
      vim.api.nvim_buf_set_keymap(stack_buf, 'n', 'q', ':q<CR>', {noremap = true, silent = true})
    end
    
    vim.api.nvim_win_set_buf(stack_win, stack_buf)
    vim.api.nvim_win_set_option(stack_win, 'number', false)
    vim.api.nvim_win_set_option(stack_win, 'relativenumber', false)
    vim.api.nvim_win_set_option(stack_win, 'wrap', false)
    vim.api.nvim_win_set_width(stack_win, 50) -- Default width
    
    -- Setup resize autocmd
    vim.api.nvim_create_autocmd("WinResized", {
      buffer = stack_buf,
      callback = function()
        M.refresh()
      end,
    })
  end
  
  M.refresh()
end

-- Auto-reload
function M.start_auto_reload()
  if timer then timer:stop() end
  timer = vim.loop.new_timer()
  timer:start(0, 2000, vim.schedule_wrap(function() -- 2s refresh
    if stack_win and vim.api.nvim_win_is_valid(stack_win) then
      M.refresh()
    end
  end))
end

function M.stop_auto_reload()
  if timer then timer:stop() timer = nil end
end

return M
