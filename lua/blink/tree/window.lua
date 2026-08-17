local api = vim.api

local Window = {}

function Window:hide_cursor()
  if self.prev_cursor ~= nil then return end

  self.prev_cursor = api.nvim_get_option_value('guicursor', {})
  api.nvim_set_option_value('guicursor', 'n:block-Cursor', {})

  local cursor_hl = api.nvim_get_hl(0, { name = 'Cursor' })
  self.prev_cursor_blend = cursor_hl.blend
  api.nvim_set_hl(0, 'Cursor', vim.tbl_extend('force', cursor_hl, { blend = 100 }))
end

function Window:restore_cursor()
  if self.prev_cursor == nil then return end

  api.nvim_set_option_value('guicursor', self.prev_cursor, {})
  self.prev_cursor = nil

  local cursor_hl = api.nvim_get_hl(0, { name = 'Cursor' })
  api.nvim_set_hl(0, 'Cursor', vim.tbl_extend('force', cursor_hl, { blend = self.prev_cursor_blend or 0 }))
  self.prev_cursor_blend = nil
end

function Window.new()
  local self = setmetatable({}, { __index = Window })
  self.winnr = -1
  self.bufnr = -1
  self.tree = require('blink.tree.tree').new(vim.fn.getcwd(), function(callback) self:render(callback) end)

  self.augroup = api.nvim_create_augroup('BlinkTreeWindow', { clear = true })

  api.nvim_create_autocmd('VimLeavePre', {
    group = self.augroup,
    callback = function()
      self:restore_cursor()
      if self.tree ~= nil then
        self.tree:destroy()
        self.tree = nil
      end
    end,
  })

  api.nvim_create_autocmd('WinEnter', {
    group = self.augroup,
    callback = function()
      local current_win = api.nvim_get_current_win()
      if current_win == self.winnr then
        api.nvim_feedkeys(api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
        self:hide_cursor()
      end
    end,
  })
  api.nvim_create_autocmd('WinLeave', {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_win() == self.winnr then self:restore_cursor() end
    end,
  })
  -- only allow the cursor to be on the first column which will always be empty
  -- avoiding issues with cursorword plugins
  api.nvim_create_autocmd('CursorMoved', {
    group = self.augroup,
    callback = function()
      if self.winnr == api.nvim_get_current_win() then
        local cursor = api.nvim_win_get_cursor(self.winnr)
        api.nvim_win_set_cursor(self.winnr, { cursor[1], 0 })
      end
    end,
  })

  -- recreate the tree on dir change
  api.nvim_create_autocmd('DirChanged', {
    group = self.augroup,
    callback = function()
      if not self.renderer then return end

      self.tree:destroy()
      self.tree = require('blink.tree.tree').new(vim.fn.getcwd(), function() self:render() end)
    end,
  })

  return self
end

function Window:refresh()
  -- todo:
end

function Window:ensure_buffer()
  -- TODO: should check if buffer is valid and cleanup previous
  if api.nvim_buf_is_valid(self.bufnr) then return end

  self.bufnr = api.nvim_create_buf(false, true)
  api.nvim_set_option_value('buftype', 'nofile', { buf = self.bufnr })
  api.nvim_set_option_value('filetype', 'blink-tree', { buf = self.bufnr })
  api.nvim_set_option_value('buflisted', false, { buf = self.bufnr })
  api.nvim_set_option_value('modifiable', false, { buf = self.bufnr })
  api.nvim_set_option_value('swapfile', false, { buf = self.bufnr })

  self.renderer = require('blink.tree.renderer').new(self.bufnr)

  require('blink.tree.binds').attach_to_instance(self)
end

function Window:configure_window()
  api.nvim_set_option_value('winfixbuf', true, { win = self.winnr })
  api.nvim_set_option_value('winfixwidth', true, { win = self.winnr })
  api.nvim_set_option_value('cursorline', true, { win = self.winnr })
  api.nvim_set_option_value('cursorlineopt', 'line', { win = self.winnr })
  api.nvim_set_option_value('signcolumn', 'no', { win = self.winnr })
  api.nvim_set_option_value('wrap', false, { win = self.winnr })
  api.nvim_set_option_value('list', false, { win = self.winnr })
  api.nvim_set_option_value('spell', false, { win = self.winnr })
  api.nvim_set_option_value('number', false, { win = self.winnr })
  api.nvim_set_option_value('relativenumber', false, { win = self.winnr })
  api.nvim_set_option_value(
    'winhighlight',
    'Normal:BlinkTreeNormal,NormalNC:BlinkTreeNormalNC,SignColumn:BlinkTreeSignColumn,CursorLine:BlinkTreeCursorLine,FloatBorder:BlinkTreeFloatBorder,StatusLine:BlinkTreeStatusLine,StatusLineNC:BlinkTreeStatusLineNC,VertSplit:BlinkTreeVertSplit,EndOfBuffer:BlinkTreeEndOfBuffer',
    { win = self.winnr }
  )
end

function Window:render(callback)
  vim.schedule(function()
    if not self:is_open() then return end
    self.nodes_by_line = self.renderer:render_window(self.winnr, self.tree.root)
    if callback then callback() end
  end)
end

function Window:open(silent, callback)
  self:ensure_buffer()
  if self:is_open() then
    if callback then callback() end
    return
  end

  self.winnr = api.nvim_open_win(self.bufnr, false, {
    win = -1,
    vertical = true,
    split = 'left',
    width = 40,
  })
  self:configure_window()

  if not silent then api.nvim_set_current_win(self.winnr) end

  self:render(callback)
end

function Window:close()
  if not self:is_open() then return end

  self:restore_cursor()

  local normal_window_count = 0
  for _, winnr in ipairs(api.nvim_list_wins()) do
    local config = api.nvim_win_get_config(winnr)
    if config.relative == '' and not config.external and not config.hide then
      normal_window_count = normal_window_count + 1
    end
  end

  -- floats and external windows cannot keep neovim open when the last normal window closes
  if normal_window_count == 1 then
    api.nvim_set_option_value('winfixbuf', false, { win = self.winnr })
    api.nvim_win_set_buf(self.winnr, api.nvim_create_buf(true, false))
    api.nvim_buf_delete(self.bufnr, { force = true })
    self.winnr = -1
    return
  end

  -- otherwise close the window
  -- todo: destroy renderer?
  api.nvim_win_close(self.winnr, true)
  api.nvim_buf_delete(self.bufnr, { force = true })
  self.winnr = -1
end

function Window:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function Window:toggle_focus()
  if not self:is_open() then return self:open() end

  local win = api.nvim_get_current_win()
  if win == self.winnr then
    vim.cmd('wincmd p')
  else
    api.nvim_set_current_win(self.winnr)
  end
end

function Window:focus()
  if not self:is_open() then return self:open() end
  api.nvim_set_current_win(self.winnr)
end

function Window:is_open()
  return api.nvim_win_is_valid(self.winnr)
    and api.nvim_win_get_buf(self.winnr) == self.bufnr
    and api.nvim_buf_is_valid(self.bufnr)
end

function Window:reveal(silent)
  local current_buf_path = vim.fn.expand(vim.api.nvim_buf_get_name(0))
  if current_buf_path == '' then return end

  self:open(silent, function()
    self.tree:expand_path(current_buf_path, function() self.renderer:select_path(current_buf_path) end)
    if not silent then self:focus() end
  end)
end

return Window
