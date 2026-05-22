-- ─── Runner State ──────────────────────────────────────────
local runner_dep_added = false
local block_index = 0
local has_runner_blocks = false

local function escape_html(text)
  return text
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
end

local function ensure_runner_dep()
  if runner_dep_added then return end
  quarto.doc.add_html_dependency({
    name = "unity-runner",
    version = "1.0.0",
    stylesheets = { "unity-runner.css" },
    scripts = { { path = "unity-runner.js", afterBody = true } }
  })
  runner_dep_added = true
end

local function wrap_with_runner(content_el, exec_type, label)
  ensure_runner_dep()
  has_runner_blocks = true

  block_index = block_index + 1
  local block_id = "ub-" .. block_index

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
    escape_html(label), block_id, block_id, block_id, block_id
  ))

  local output_panel = pandoc.RawBlock("html", string.format(
    [[<pre class="unity-output" id="%s-output"></pre>]],
    block_id
  ))

  return pandoc.Div(
    { toolbar, content_el, output_panel },
    pandoc.Attr(block_id, { "unity-block" }, { ["data-exec-type"] = exec_type })
  )
end


-- ─── Card Helpers ─────────────────────────────────────────
local function has(classes, name)
  return classes:includes(name)
end

local function escape(text)
  return (text:gsub('[&<>]', { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;' }))
end

local function tag(label, kind)
  return '<span class="u-tag u-tag-' .. kind .. '">' .. label .. '</span>'
end

local function is_total(text)
  return text:match('%f[%a]return%f[%A]') ~= nil
end


-- ─── exec Block ──────────────────────────────────────────
local function exec_card(block)
  local name = block.attributes['name'] or 'exec'
  local usings = block.attributes['usings']
  local total = is_total(block.text)
  local state = total and 'total' or 'partial'
  if not total then
    io.stderr:write('[unity-cli] PARTIAL exec block (no return): ' .. name .. '\n')
  end

  -- Build the shell command the runner will execute
  local run_code
  if usings then
    run_code = "cat << 'CSHARP' | unity-cli exec --usings " .. usings .. "\n" .. block.text .. "\nCSHARP"
  else
    run_code = "cat << 'CSHARP' | unity-cli exec\n" .. block.text .. "\nCSHARP"
  end

  local head = pandoc.RawBlock('html',
    '<div class="u-card-head">' .. tag('exec', 'inspect') ..
    '<span class="u-card-name">' .. escape(name) .. '</span>' ..
    (total and tag('total', 'verify') or tag('partial', 'fail')) .. '</div>')
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { 'csharp' }))
  local foot = pandoc.RawBlock('html', '<div class="u-card-foot"><code>CSHARP</code></div>')

  local card = pandoc.Div({ head, code, foot }, pandoc.Attr('', { 'u-card', 'u-exec', state }))
  local wrapped = wrap_with_runner(card, "exec", name)

  -- Hidden element with the actual runnable shell command
  local hidden = pandoc.RawBlock('html', '<pre class="unity-run-code" style="display:none">' .. escape(run_code) .. '</pre>')
  table.insert(wrapped.content, hidden)
  return wrapped
end


-- ─── cli Block ───────────────────────────────────────────
local function cli_card(block)
  local name = block.attributes['name'] or 'cli'
  local head = pandoc.RawBlock('html',
    '<div class="u-card-head">' .. tag('cli', 'mutate') ..
    '<span class="u-card-name">' .. escape(name) .. '</span></div>')
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { 'bash' }))
  local card = pandoc.Div({ head, code }, pandoc.Attr('', { 'u-card', 'u-cli' }))
  return wrap_with_runner(card, "cli", name)
end


-- ─── Wrong/Right Blocks ──────────────────────────────────
local function labeled_code(block, kind, label)
  local lang = block.attributes['lang'] or 'csharp'
  local head = pandoc.RawBlock('html', '<div class="u-code-label u-code-' .. kind .. '">' .. label .. '</div>')
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { lang }))
  return pandoc.Div({ head, code }, pandoc.Attr('', { 'u-codeblock', 'u-' .. kind }))
end


-- ─── CodeBlock Filter ────────────────────────────────────
function CodeBlock(block)
  if has(block.classes, 'exec') then return exec_card(block) end
  if has(block.classes, 'cli') then return cli_card(block) end
  if has(block.classes, 'wrong') then return labeled_code(block, 'wrong', '&#10007; WRONG') end
  if has(block.classes, 'right') then return labeled_code(block, 'right', '&#10003; RIGHT') end
  return nil
end


-- ─── Callout Divs ────────────────────────────────────────
local callouts = {
  axiom = { label = 'AXIOM', kind = 'axiom' },
  gotcha = { label = 'GOTCHA', kind = 'gotcha' },
  failure = { label = 'HARD FAILURE', kind = 'fail' },
  verify = { label = 'VERIFY', kind = 'verify' },
}

function Div(div)
  for cls, spec in pairs(callouts) do
    if has(div.classes, cls) then
      local title = div.attributes['title']
      local head = pandoc.RawBlock('html',
        '<div class="u-callout-head">' .. tag(spec.label, spec.kind) ..
        (title and ('<span class="u-callout-title">' .. escape(title) .. '</span>') or '') .. '</div>')
      local body = pandoc.Div(div.content, pandoc.Attr('', { 'u-callout-body' }))
      return pandoc.Div({ head, body }, pandoc.Attr('', { 'u-callout', 'u-' .. spec.kind }))
    end
  end
  return nil
end


-- ─── Pandoc Final (inject status bar) ────────────────────
function Pandoc(doc)
  if not has_runner_blocks then return nil end

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
