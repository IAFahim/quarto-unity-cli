local function field(meta, key, fallback)
  if meta[key] ~= nil then
    return pandoc.utils.stringify(meta[key])
  end
  return fallback
end

return {
  ['unity-type'] = function(args, kwargs, meta)
    local name = pandoc.utils.stringify(args[1])
    return pandoc.RawInline('html', '<code class="u-type">' .. name .. '</code>')
  end,
  ['unity-version'] = function(args, kwargs, meta)
    return pandoc.Str(field(meta, 'unity-cli-version', '0.3.19'))
  end,
}
