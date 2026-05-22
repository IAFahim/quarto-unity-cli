local dependency_injected = false
local block_counter = 0
local has_blocks = false
local name_to_id = {}

local EXEC_KINDS = { cs = true, csharp = true }
local INTENT_KINDS = { query = true, assert = true, setup = true, teardown = true }
local META_ATTRS = { "title", "name", "depends", "group", "format", "timeout", "expected", "cache", "usings" }

local ICON_PLAY = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="5,3 19,12 5,21"/></svg>'
local ICON_STOP = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="4" y="4" width="16" height="16" rx="2"/></svg>'
local ICON_CLEAR = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>'
local ICON_COPY = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>'
local ICON_CLIPBOARD = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 4h2a2 2 0 012 2v14a2 2 0 01-2 2H6a2 2 0 01-2-2V6a2 2 0 012-2h2"/><rect x="8" y="2" width="8" height="4" rx="1"/></svg>'
local ICON_FOLD = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="6 9 12 15 18 9"/></svg>'
local ICON_FROM_HERE = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5,3 19,12 5,21" fill="currentColor"/><line x1="19" y1="3" x2="19" y2="21"/></svg>'


local function escape(text)
  return text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end


local function detect_kind(classes)
  for _, cls in ipairs(classes) do
    if EXEC_KINDS[cls] then return "exec" end
  end
  return "cli"
end


local function detect_intent(classes)
  for _, cls in ipairs(classes) do
    if INTENT_KINDS[cls] then return cls end
  end
  return "run"
end


local function strip_meta_classes(classes)
  local keep = pandoc.List()
  for _, cls in ipairs(classes) do
    if cls ~= "unity" and not INTENT_KINDS[cls] then
      keep:insert(cls)
    end
  end
  return keep
end


local function build_data_attrs(kind, intent, attrs)
  local parts = {
    string.format('data-kind="%s"', kind),
    string.format('data-intent="%s"', intent),
  }
  for _, key in ipairs(META_ATTRS) do
    local val = attrs[key]
    if val and val ~= "" then
      table.insert(parts, string.format('data-%s="%s"', key, escape(val)))
    end
  end
  return table.concat(parts, " ")
end


local function intent_badge(intent)
  if intent == "run" then return "" end
  return string.format(
    '<span class="ur-intent-badge" data-intent="%s">%s</span>',
    intent, intent:upper()
  )
end


local function depends_tag(raw)
  if not raw or raw == "" then return "" end
  return string.format(
    '<span class="ur-depends-tag" title="depends on: %s">\xe2\x9f\xb5 %s</span>',
    escape(raw), escape(raw)
  )
end


local function make_label(kind, intent, title)
  if title and title ~= "" then return escape(title) end
  if kind == "exec" then return "C# \xe2\x86\x92 Unity" end
  return "unity-cli"
end


local function ensure_deps()
  if dependency_injected then return end
  quarto.doc.add_html_dependency({
    name = "unity-runner",
    version = "2.0.0",
    stylesheets = { "unity-runner.css" },
    scripts = { { path = "unity-runner.js", afterBody = true } },
  })
  dependency_injected = true
end


function CodeBlock(block)
  if not block.classes:includes("unity") then return nil end

  ensure_deps()
  has_blocks = true
  block_counter = block_counter + 1

  local bid = "ub-" .. block_counter
  local kind = detect_kind(block.classes)
  local intent = detect_intent(block.classes)
  local title = block.attributes["title"]
  local name = block.attributes["name"]
  local deps = block.attributes["depends"]
  local label = make_label(kind, intent, title)
  local data = build_data_attrs(kind, intent, block.attributes)

  if name then name_to_id[name] = bid end

  block.classes = strip_meta_classes(block.classes)
  for _, key in ipairs(META_ATTRS) do block.attributes[key] = nil end

  local toolbar = string.format(
    [[<div class="ur-toolbar">
  <div class="ur-toolbar-left">%s<span class="ur-block-label">%s</span></div>
  <div class="ur-toolbar-right">
    %s
    <span class="ur-elapsed" id="%s-elapsed"></span>
    <button class="ur-btn ur-copy-code-btn" data-target="%s" title="Copy code">%s</button>
    <button class="ur-btn ur-copy-output-btn" data-target="%s" title="Copy output" style="display:none">%s</button>
    <button class="ur-btn ur-fold-btn" data-target="%s" title="Toggle output" style="display:none">%s</button>
    <button class="ur-btn ur-from-here-btn" data-target="%s" title="Run from here">%s</button>
    <button class="ur-btn ur-run-btn" data-target="%s" title="Run">
      <span class="ur-icon-play">%s</span>
      <span class="ur-icon-stop">%s</span>
    </button>
    <button class="ur-btn ur-clear-btn" data-target="%s" title="Clear">%s</button>
  </div>
</div>]],
    intent_badge(intent), label,
    depends_tag(deps),
    bid,
    bid, ICON_COPY,
    bid, ICON_CLIPBOARD,
    bid, ICON_FOLD,
    bid, ICON_FROM_HERE,
    bid, ICON_PLAY, ICON_STOP,
    bid, ICON_CLEAR
  )

  local output_panel = string.format(
    [[<div class="ur-output-panel" id="%s-panel">
  <pre class="ur-output" id="%s-output"></pre>
  <div class="ur-assert-result" id="%s-assert"></div>
</div>]],
    bid, bid, bid
  )

  return {
    pandoc.RawBlock("html", string.format('<div id="%s" class="ur-block" %s>', bid, data)),
    pandoc.RawBlock("html", toolbar),
    block,
    pandoc.RawBlock("html", output_panel),
    pandoc.RawBlock("html", "</div>"),
  }
end


function Pandoc(doc)
  if not has_blocks then return nil end

  local registry_parts = {}
  for name, id in pairs(name_to_id) do
    table.insert(registry_parts, string.format('"%s":"%s"', name, id))
  end
  local registry_json = "{" .. table.concat(registry_parts, ",") .. "}"

  local status_bar = pandoc.RawBlock("html", string.format(
    [[<div id="ur-status-bar">
  <div class="ur-status-left">
    <span class="ur-status-dot" id="ur-dot"></span>
    <span class="ur-status-text" id="ur-status-text">Disconnected</span>
  </div>
  <div class="ur-status-right">
    <span class="ur-kbd-hint"><kbd>Ctrl</kbd><kbd>Enter</kbd> run block · <kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>Enter</kbd> run all</span>
    <button class="ur-btn" id="ur-run-all-btn" disabled>%s Run All</button>
  </div>
</div>
<script type="application/json" id="ur-block-registry">%s</script>]],
    ICON_PLAY, registry_json
  ))

  table.insert(doc.blocks, 1, status_bar)
  return doc
end
