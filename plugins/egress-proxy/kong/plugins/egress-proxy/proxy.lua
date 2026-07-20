-- Core logic for egress-proxy: building the absolute-form request URI
-- that a forward proxy (RFC 7230 §5.3.2) expects, the Proxy-Authorization
-- header, and hop-by-hop header filtering for the re-sent hop.

local M = {}

-- Absolute-form target for the proxy's request line:
--   "http://host[:port]/path[?query]"
--
-- upstream_uri is the path Kong computed in access.before (service.path +
-- route strip_path handling, possibly rewritten by other plugins). The
-- query string is appended here — the plugin re-sends the request itself,
-- so Kong core's own "?args" append in access.after never reaches the
-- proxy hop. Guarded: a path that already carries a query (a plugin that
-- rewrote upstream_uri with one) is left alone.
-- "host[:port]" for the Service — used both in the absolute URI and as
-- the Host header. They must agree: Squid treats the URI authority as
-- authoritative and rewrites a mismatching Host from it.
function M.authority(service)
  local authority = service.host
  local port = service.port or 80
  if port ~= 80 then
    authority = authority .. ":" .. port
  end
  return authority
end

function M.absolute_target(service, upstream_uri, query)
  local path = upstream_uri
  if path == nil or path == "" then
    path = "/"
  end
  if query and query ~= "" and not path:find("?", 1, true) then
    path = path .. "?" .. query
  end
  return "http://" .. M.authority(service) .. path
end

function M.basic_auth(username, password)
  return "Basic " .. ngx.encode_base64(username .. ":" .. (password or ""))
end

-- Hop-by-hop headers (RFC 7230 §6.1) must not travel past this hop; the
-- plugin re-sends the request itself, so it owns this filtering. Host is
-- rebuilt from the Service entity; Content-Length is recomputed from the
-- body by the http client.
local DROP_FROM_REQUEST = {
  ["host"] = true,
  ["connection"] = true,
  ["keep-alive"] = true,
  ["te"] = true,
  ["trailers"] = true,
  ["transfer-encoding"] = true,
  ["upgrade"] = true,
  ["proxy-connection"] = true,
  ["proxy-authorization"] = true,
  ["content-length"] = true,
}

function M.outbound_headers(request_headers, origin_host, proxy_auth)
  local out = {}
  for name, value in pairs(request_headers) do
    if not DROP_FROM_REQUEST[name:lower()] then
      out[name] = value
    end
  end
  out["Host"] = origin_host
  if proxy_auth then
    out["Proxy-Authorization"] = proxy_auth
  end
  return out
end

local DROP_FROM_RESPONSE = {
  ["connection"] = true,
  ["keep-alive"] = true,
  ["te"] = true,
  ["trailer"] = true,
  ["transfer-encoding"] = true,
  ["upgrade"] = true,
  ["proxy-authenticate"] = true,
  ["content-length"] = true,
}

function M.response_headers(headers)
  local out = {}
  for name, value in pairs(headers) do
    if not DROP_FROM_RESPONSE[name:lower()] then
      out[name] = value
    end
  end
  return out
end

return M
