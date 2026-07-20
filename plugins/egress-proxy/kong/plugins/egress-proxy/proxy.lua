-- Core logic for egress-proxy: building the absolute-form request URI
-- that a forward proxy (RFC 7230 §5.3.2) expects, and the
-- Proxy-Authorization header.

local M = {}

-- Absolute-form target for the proxy's request line:
--   "http://host[:port]/path"
--
-- upstream_uri is the path Kong computed in access.before (service.path +
-- route strip_path handling, possibly rewritten by other plugins). The
-- query string must NOT be added here: Kong core appends "?args" to
-- ngx.var.upstream_uri in access.after, AFTER plugin access runs — so it
-- lands on the absolute URI automatically.
function M.absolute_target(service, upstream_uri)
  local authority = service.host
  local port = service.port or 80
  if port ~= 80 then
    authority = authority .. ":" .. port
  end
  local path = upstream_uri
  if path == nil or path == "" then
    path = "/"
  end
  return "http://" .. authority .. path
end

function M.basic_auth(username, password)
  return "Basic " .. ngx.encode_base64(username .. ":" .. (password or ""))
end

return M
