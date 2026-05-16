local dependency_added = false
local block_index = 0
local has_unity_blocks = false

local function escape_html(text)
  return text
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
end

local function without_class(classes, target)
  local filtered = pandoc.List()
  for _, cls in ipairs(classes) do
    if cls ~= target then
      filtered:insert(cls)
    end
  end
  return filtered
end

local function detect_exec_type(classes)
  for _, cls in ipairs(classes) do
    if cls == "cs" or cls == "csharp" then
      return "exec"
    end
  end
  return "cli"
end

local function make_label(exec_type, custom_title)
  if custom_title and custom_title ~= "" then
    return escape_html(custom_title)
  end
  if exec_type == "exec" then
    return "C# → Unity"
  end
  return "unity-cli"
end

local function ensure_dependency()
  if dependency_added then
    return
  end
  quarto.doc.add_html_dependency({
    name = "unity-runner",
    version = "1.0.0",
    stylesheets = { "unity-runner.css" },
    scripts = { { path = "unity-runner.js", afterBody = true } }
  })
  dependency_added = true
end

function CodeBlock(block)
  if not block.classes:includes("unity") then
    return nil
  end

  ensure_dependency()
  has_unity_blocks = true

  block_index = block_index + 1
  local block_id = "ub-" .. block_index
  local exec_type = detect_exec_type(block.classes)
  local custom_title = block.attributes["title"]
  local label = make_label(exec_type, custom_title)

  block.classes = without_class(block.classes, "unity")
  block.attributes["title"] = nil

  local toolbar = pandoc.RawBlock("html", string.format(
    [[<div class="unity-toolbar">
  <span class="unity-label">%s</span>
  <div class="unity-controls">
    <span class="unity-elapsed" id="%s-elapsed"></span>
    <button class="unity-btn unity-copy-btn" data-target="%s" title="Copy code">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>
    </button>
    <button class="unity-btn unity-run-btn" data-target="%s" title="Run">
      <svg class="unity-icon-play" width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="5,3 19,12 5,21"/></svg>
      <svg class="unity-icon-stop" width="14" height="14" viewBox="0 0 24 24" fill="currentColor" style="display:none"><rect x="4" y="4" width="16" height="16" rx="2"/></svg>
    </button>
    <button class="unity-btn unity-clear-btn" data-target="%s" title="Clear output">
      <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
    </button>
  </div>
</div>]],
    label, block_id, block_id, block_id, block_id
  ))

  local output_panel = pandoc.RawBlock("html", string.format(
    [[<pre class="unity-output" id="%s-output"></pre>]],
    block_id
  ))

  return pandoc.Div(
    { toolbar, block, output_panel },
    pandoc.Attr(block_id, { "unity-block" }, { ["data-exec-type"] = exec_type })
  )
end

function Pandoc(doc)
  if not has_unity_blocks then
    return nil
  end

  local status_bar = pandoc.RawBlock("html", [[<div id="unity-status-bar">
  <div class="unity-status-left">
    <span class="unity-status-dot" id="unity-dot"></span>
    <span class="unity-status-text" id="unity-status-text">Disconnected</span>
  </div>
  <div class="unity-status-right">
    <button class="unity-btn" id="unity-run-all-btn" disabled>
      <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="5,3 19,12 5,21"/></svg>
      Run All
    </button>
  </div>
</div>]])

  table.insert(doc.blocks, 1, status_bar)
  return doc
end
