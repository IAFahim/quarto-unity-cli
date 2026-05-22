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

local function exec_card(block)
  local name = block.attributes['name'] or 'exec'
  local usings = block.attributes['usings']
  local total = is_total(block.text)
  local state = total and 'total' or 'partial'
  if not total then
    io.stderr:write('[unity-cli] PARTIAL exec block (no return): ' .. name .. '\n')
  end
  local invocation = "cat << 'CSHARP' | unity-cli exec"
  if usings then
    invocation = invocation .. ' --usings ' .. usings
  end
  local head = pandoc.RawBlock('html',
    '<div class="u-card-head">' .. tag('exec', 'inspect') ..
    '<span class="u-card-name">' .. escape(name) .. '</span>' ..
    (total and tag('total', 'verify') or tag('partial', 'fail')) .. '</div>')
  local invo = pandoc.RawBlock('html',
    '<div class="u-card-invocation"><code>' .. escape(invocation) .. '</code></div>')
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { 'csharp' }))
  local foot = pandoc.RawBlock('html', '<div class="u-card-foot"><code>CSHARP</code></div>')
  return pandoc.Div({ head, invo, code, foot }, pandoc.Attr('', { 'u-card', 'u-exec', state }))
end

local function cli_card(block)
  local name = block.attributes['name'] or 'cli'
  local head = pandoc.RawBlock('html',
    '<div class="u-card-head">' .. tag('cli', 'mutate') ..
    '<span class="u-card-name">' .. escape(name) .. '</span></div>')
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { 'bash' }))
  return pandoc.Div({ head, code }, pandoc.Attr('', { 'u-card', 'u-cli' }))
end

local function labeled_code(block, kind, label)
  local lang = block.attributes['lang'] or 'csharp'
  local head = pandoc.RawBlock('html', '<div class="u-code-label u-code-' .. kind .. '">' .. label .. '</div>')
  local code = pandoc.CodeBlock(block.text, pandoc.Attr('', { lang })) 
  return pandoc.Div({ head, code }, pandoc.Attr('', { 'u-codeblock', 'u-' .. kind }))
end

function CodeBlock(block)
  if has(block.classes, 'exec') then return exec_card(block) end
  if has(block.classes, 'cli') then return cli_card(block) end
  if has(block.classes, 'wrong') then return labeled_code(block, 'wrong', '&#10007; WRONG') end
  if has(block.classes, 'right') then return labeled_code(block, 'right', '&#10003; RIGHT') end
  return nil
end

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
