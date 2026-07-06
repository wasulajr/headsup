local wezterm = require 'wezterm'

local config = {}
if wezterm.config_builder then
  config = wezterm.config_builder()
end

config.enable_tab_bar = true
config.hide_tab_bar_if_only_one_tab = false
config.use_fancy_tab_bar = false
config.show_new_tab_button_in_tab_bar = false
config.max_fps = 60
config.animation_fps = 1
config.audible_bell = 'Disabled'
config.check_for_updates = false
config.term = 'wezterm'

config.colors = {
  tab_bar = {
    background = '#111827',
    inactive_tab = { bg_color = '#1f2937', fg_color = '#d1d5db' },
    inactive_tab_hover = { bg_color = '#374151', fg_color = '#f9fafb' },
    active_tab = { bg_color = '#3a82f5', fg_color = '#ffffff' },
    new_tab = { bg_color = '#111827', fg_color = '#9ca3af' },
    new_tab_hover = { bg_color = '#374151', fg_color = '#f9fafb' },
  },
}

local state_colors = {
  idle = '#ffffff',
  processing = '#3a82f5',
  waiting = '#e67e22',
}

local function contrast_for(bg)
  bg = (bg or ''):lower()
  if bg == '#ffffff' or bg == 'ffffff' then
    return '#111827'
  end
  return '#ffffff'
end

local function tab_label(tab)
  local pane = tab.active_pane
  local vars = pane.user_vars or {}
  local label = vars.headsup_label
  if label and #label > 0 then
    return label
  end
  if tab.tab_title and #tab.tab_title > 0 then
    return tab.tab_title
  end
  return pane.title
end

wezterm.on('format-tab-title', function(tab, tabs, panes, effective_config, hover, max_width)
  local vars = tab.active_pane.user_vars or {}
  local state = vars.headsup_state or ''
  local background = vars.headsup_color

  if not background or #background == 0 then
    background = state_colors[state]
  end
  if not background or #background == 0 then
    background = tab.is_active and '#374151' or '#1f2937'
  end

  local title = tab_label(tab)
  if max_width and max_width > 4 then
    title = wezterm.truncate_right(title, max_width - 2)
  end

  return {
    { Background = { Color = background } },
    { Foreground = { Color = contrast_for(background) } },
    { Text = ' ' .. title .. ' ' },
  }
end)

return config
