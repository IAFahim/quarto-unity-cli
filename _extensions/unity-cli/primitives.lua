-- ═══════════════════════════════════════════════════════════
-- unity-cli extension — merged primitives + v2 runner
-- ═══════════════════════════════════════════════════════════

-- ─── Runner State ──────────────────────────────────────────
local dep_injected = false
local block_counter = 0
local has_blocks = false
local name_to_id = {}

-- ─── SVG Icons ─────────────────────────────────────────────
local ICON_PLAY  = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="5,3 19,12 5,21"/></svg>'
local ICON_STOP  = '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="4" y="4" width="16" height="16" rx="2"/></svg>'
local ICON_CLEAR = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>'
local ICON_COPY  = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 01-2-2V4a2 2 0 012-2h9a2 2 0 012 2v1"/></svg>'
local ICON_CLIP  = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M16 4h2a2 2 0 012 2v14a2 2 0 01-2 2H6a2 2 0 01-2-2V6a2 2 0 012-2h2"/><rect x="8" y="2" width="8" height="4" rx="1"/></svg>'
local ICON_FOLD  = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="6 9 12 15 18 9"/></svg>'
local ICON_CHAIN = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polygon points="5,3 19,12 5,21" fill="currentColor"/><line x1="19" y1="3" x2="19" y2="21"/></svg>'

-- ─── Helpers ───────────────────────────────────────────────
local function has(classes, name)
  return classes:includes(name)
end

local function esc(text)
  return (text:gsub('[&<>"]', { ['&'] = '&amp;', ['<'] = '&lt;', ['>'] = '&gt;', ['"'] = '&quot;' }))
end

local function tag(label, kind)
  return '<span class="u-tag u-tag-' .. kind .. '">' .. label .. '</span>'
end

local function is_total(text)
  return text:match('%f[%a]return%f[%A]') ~= nil
end

local function attr_val(attrs, key)
  if attrs[key] ~= nil and attrs[key] ~= '' then
    return ' data-' .. key .. '="' .. esc(attrs[key]) .. '"'
  end
  return ''
end

-- ─── Dependency Injection ──────────────────────────────────
local function ensure_deps()
  if dep_injected then return end
  quarto.doc.add_html_dependency({
    name = "unity-runner",
    version = "2.0.0",
    stylesheets = { "unity-runner.css" },
    scripts = { { path = "unity-runner.js", afterBody = true } },
  })
  dep_injected = true
end


-- ═════════════════════════════════════════════════════════════
-- exec blocks  ({.exec name="..." usings="..."})
-- ═════════════════════════════════════════════════════════════
local function exec_card(block)
  local name = block.attributes['name'] or 'exec'
  local usings = block.attributes['usings'] or ''
  local total = is_total(block.text)
  local state = total and 'total' or 'partial'

  if not total then
    io.stderr:write('[unity-cli] PARTIAL exec block (no return): ' .. name .. '\n')
  end

  ensure_deps()
  has_blocks = true
  block_counter = block_counter + 1
  local bid = "ub-" .. block_counter

  -- Card head
  local head_html =
    '<div class="u-card-head">' .. tag('exec', 'inspect') ..
    '<span class="u-card-name">' .. esc(name) .. '</span>' ..
    (total and tag('total', 'verify') or tag('partial', 'fail')) .. '</div>'

  -- Code block (visible, syntax-highlighted C#)
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { 'csharp' }))

  -- Card foot
  local foot_html = '<div class="u-card-foot"><code>CSHARP</code></div>'

  -- Runner data attributes
  local data_attrs =
    'data-kind="exec"' ..
    ' data-intent="run"' ..
    attr_val(block.attributes, 'depends') ..
    attr_val(block.attributes, 'timeout')

  if usings ~= '' then
    data_attrs = data_attrs .. ' data-usings="' .. esc(usings) .. '"'
  end

  -- Toolbar
  local toolbar = string.format(
    [[<div class="ur-toolbar">
  <div class="ur-toolbar-left"><span class="ur-block-label">%s</span></div>
  <div class="ur-toolbar-right">
    <span class="ur-elapsed" id="%s-elapsed"></span>
    <button class="ur-btn ur-copy-code-btn" data-target="%s" title="Copy code">%s</button>
    <button class="ur-btn ur-copy-output-btn" data-target="%s" title="Copy output" style="display:none">%s</button>
    <button class="ur-btn ur-fold-btn" data-target="%s" title="Toggle output" style="display:none">%s</button>
    <button class="ur-btn ur-from-here-btn" data-target="%s" title="Run from here">%s</button>
    <button class="ur-btn ur-run-btn" data-target="%s" title="Run">
      <span class="ur-icon-play">%s</span><span class="ur-icon-stop">%s</span>
    </button>
    <button class="ur-btn ur-clear-btn" data-target="%s" title="Clear">%s</button>
  </div>
</div>]],
    esc(name), bid,
    bid, ICON_COPY,
    bid, ICON_CLIP,
    bid, ICON_FOLD,
    bid, ICON_CHAIN,
    bid, ICON_PLAY, ICON_STOP,
    bid, ICON_CLEAR
  )

  -- Output panel
  local output_panel = string.format(
    [[<div class="ur-output-panel" id="%s-panel"><pre class="ur-output" id="%s-output"></pre></div>]],
    bid, bid
  )

  if block.attributes['name'] then
    name_to_id[block.attributes['name']] = bid
  end

  -- Open wrapper, toolbar, card, output panel, close wrapper
  return {
    pandoc.RawBlock("html", string.format('<div id="%s" class="ur-block" %s>', bid, data_attrs)),
    pandoc.RawBlock("html", toolbar),
    pandoc.Div(
      { pandoc.RawBlock("html", head_html), code, pandoc.RawBlock("html", foot_html) },
      pandoc.Attr('', { 'u-card', 'u-exec', state })
    ),
    pandoc.RawBlock("html", output_panel),
    pandoc.RawBlock("html", '</div>'),
  }
end


-- ═════════════════════════════════════════════════════════════
-- cli blocks  ({.cli name="..."})
-- ═════════════════════════════════════════════════════════════
local function cli_card(block)
  local name = block.attributes['name'] or 'cli'

  ensure_deps()
  has_blocks = true
  block_counter = block_counter + 1
  local bid = "ub-" .. block_counter

  -- Card head
  local head_html =
    '<div class="u-card-head">' .. tag('cli', 'mutate') ..
    '<span class="u-card-name">' .. esc(name) .. '</span></div>'

  -- Code block (visible, bash-highlighted)
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { 'bash' }))

  -- Runner data attributes
  local data_attrs =
    'data-kind="cli"' ..
    ' data-intent="run"' ..
    attr_val(block.attributes, 'depends') ..
    attr_val(block.attributes, 'timeout')

  -- Toolbar
  local toolbar = string.format(
    [[<div class="ur-toolbar">
  <div class="ur-toolbar-left"><span class="ur-block-label">%s</span></div>
  <div class="ur-toolbar-right">
    <span class="ur-elapsed" id="%s-elapsed"></span>
    <button class="ur-btn ur-copy-code-btn" data-target="%s" title="Copy code">%s</button>
    <button class="ur-btn ur-copy-output-btn" data-target="%s" title="Copy output" style="display:none">%s</button>
    <button class="ur-btn ur-fold-btn" data-target="%s" title="Toggle output" style="display:none">%s</button>
    <button class="ur-btn ur-from-here-btn" data-target="%s" title="Run from here">%s</button>
    <button class="ur-btn ur-run-btn" data-target="%s" title="Run">
      <span class="ur-icon-play">%s</span><span class="ur-icon-stop">%s</span>
    </button>
    <button class="ur-btn ur-clear-btn" data-target="%s" title="Clear">%s</button>
  </div>
</div>]],
    esc(name), bid,
    bid, ICON_COPY,
    bid, ICON_CLIP,
    bid, ICON_FOLD,
    bid, ICON_CHAIN,
    bid, ICON_PLAY, ICON_STOP,
    bid, ICON_CLEAR
  )

  -- Output panel
  local output_panel = string.format(
    [[<div class="ur-output-panel" id="%s-panel"><pre class="ur-output" id="%s-output"></pre></div>]],
    bid, bid
  )

  if block.attributes['name'] then
    name_to_id[block.attributes['name']] = bid
  end

  return {
    pandoc.RawBlock("html", string.format('<div id="%s" class="ur-block" %s>', bid, data_attrs)),
    pandoc.RawBlock("html", toolbar),
    pandoc.Div(
      { pandoc.RawBlock("html", head_html), code },
      pandoc.Attr('', { 'u-card', 'u-cli' })
    ),
    pandoc.RawBlock("html", output_panel),
    pandoc.RawBlock("html", '</div>'),
  }
end


-- ═════════════════════════════════════════════════════════════
-- wrong/right blocks  (no runner UI)
-- ═════════════════════════════════════════════════════════════
local function labeled_code(block, kind, label)
  local lang = block.attributes['lang'] or 'csharp'
  local head = pandoc.RawBlock('html', '<div class="u-code-label u-code-' .. kind .. '">' .. label .. '</div>')
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { lang }))
  return pandoc.Div({ head, code }, pandoc.Attr('', { 'u-codeblock', 'u-' .. kind }))
end


-- ═════════════════════════════════════════════════════════════
-- CodeBlock filter
-- ═════════════════════════════════════════════════════════════
function CodeBlock(block)
  if has(block.classes, 'exec') then return exec_card(block) end
  if has(block.classes, 'cli') then return cli_card(block) end
  if has(block.classes, 'wrong') then return labeled_code(block, 'wrong', '&#10007; WRONG') end
  if has(block.classes, 'right') then return labeled_code(block, 'right', '&#10003; RIGHT') end
  return nil
end


-- ═════════════════════════════════════════════════════════════
-- Callout Divs  (no runner UI)
-- ═════════════════════════════════════════════════════════════
local callouts = {
  axiom   = { label = 'AXIOM',       kind = 'axiom' },
  gotcha  = { label = 'GOTCHA',      kind = 'gotcha' },
  failure = { label = 'HARD FAILURE', kind = 'fail' },
  verify  = { label = 'VERIFY',      kind = 'verify' },
}

function Div(div)
  for cls, spec in pairs(callouts) do
    if has(div.classes, cls) then
      local title = div.attributes['title']
      local head = pandoc.RawBlock('html',
        '<div class="u-callout-head">' .. tag(spec.label, spec.kind) ..
        (title and ('<span class="u-callout-title">' .. esc(title) .. '</span>') or '') .. '</div>')
      local body = pandoc.Div(div.content, pandoc.Attr('', { 'u-callout-body' }))
      return pandoc.Div({ head, body }, pandoc.Attr('', { 'u-callout', 'u-' .. spec.kind }))
    end
  end
  return nil
end


-- ═════════════════════════════════════════════════════════════
-- Pandoc final — inject status bar + block registry
-- ═════════════════════════════════════════════════════════════
function Pandoc(doc)
  if not has_blocks then return nil end

  local reg_parts = {}
  for n, id in pairs(name_to_id) do
    table.insert(reg_parts, string.format('"%s":"%s"', n, id))
  end
  local reg_json = "{" .. table.concat(reg_parts, ",") .. "}"

  local status_bar = pandoc.RawBlock("html", string.format(
    [[<div id="ur-status-bar">
  <div class="ur-status-left">
    <span class="ur-status-dot" id="ur-dot"></span>
    <span class="ur-status-text" id="ur-status-text">Disconnected</span>
  </div>
  <div class="ur-status-right">
    <span class="ur-kbd-hint"><kbd>Ctrl</kbd><kbd>Enter</kbd> run · <kbd>Ctrl</kbd><kbd>Shift</kbd><kbd>Enter</kbd> run all</span>
    <button class="ur-btn" id="ur-run-all-btn" disabled>%s Run All</button>
  </div>
</div>
<script type="application/json" id="ur-block-registry">%s</script>]],
    ICON_PLAY, reg_json
  ))

  table.insert(doc.blocks, 1, status_bar)
  return doc
end
