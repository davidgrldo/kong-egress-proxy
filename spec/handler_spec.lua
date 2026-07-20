local t = require "spec.test_helper"

-- Full-mock harness: capture every side effect the handler produces,
-- including the resty.http hop it sends itself.
local function fresh_handler(opts)
  package.loaded["kong.plugins.egress-proxy.handler"] = nil
  package.loaded["kong.plugins.egress-proxy.proxy"] = nil

  local state = {
    connected = nil, request = nil, keepalive = false,
    exit_status = nil, exit_body = nil, exit_headers = nil,
    timeouts = nil, warned = false,
  }

  local response = opts.response or {
    status = 200,
    headers = { ["Content-Type"] = "application/json" },
    body = '{"ok":true}',
  }

  local client = {
    set_timeouts = function(_, ...) state.timeouts = { ... } end,
    connect = function(_, target)
      if opts.connect_error then return nil, opts.connect_error end
      state.connected = target
      return true
    end,
    request = function(_, req)
      state.request = req
      return {
        status = response.status,
        headers = response.headers,
        read_body = function() return response.body end,
      }
    end,
    set_keepalive = function() state.keepalive = true return true end,
  }
  package.loaded["resty.http"] = { new = function() return client end }

  _G.ngx = { var = { upstream_uri = opts.upstream_uri or "/v1/ping" },
             null = _G.ngx and _G.ngx.null or {},
             encode_base64 = function(s) return "b64(" .. s .. ")" end }

  _G.kong = {
    router = { get_service = function() return opts.service end },
    log = {
      warn = function() state.warned = true end,
      err = function() end,
      debug = function() end,
    },
    request = {
      get_method = function() return opts.method or "GET" end,
      get_raw_query = function() return opts.query or "" end,
      get_raw_body = function() return opts.body or "" end,
      get_headers = function() return opts.headers or {} end,
    },
    response = {
      -- kong.response.exit(status, body, headers): no self.
      exit = function(status, body, headers)
        state.exit_status = status
        state.exit_body = body
        state.exit_headers = headers
      end,
    },
  }

  return require "kong.plugins.egress-proxy.handler", state
end

t.test("routes an http upstream through the proxy in absolute form", function()
  local handler, state = fresh_handler({
    service = { protocol = "http", host = "api.partner.id", port = 8080 },
    upstream_uri = "/v1/orders",
    query = "a=1",
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128 })
  t.equal(state.connected.host, "squid.dmz")
  t.equal(state.connected.port, 3128)
  t.equal(state.connected.scheme, "http")
  t.equal(state.request.path, "http://api.partner.id:8080/v1/orders?a=1")
  -- Host must carry the non-default port and match the URI authority:
  -- Squid rewrites a mismatching Host from the absolute URI.
  t.equal(state.request.headers["Host"], "api.partner.id:8080")
  t.equal(state.exit_status, 200)
  t.equal(state.exit_body, '{"ok":true}')
  t.equal(state.exit_headers["Content-Type"], "application/json")
  t.truthy(state.keepalive)
end)

t.test("sets Proxy-Authorization when credentials are configured", function()
  local handler, state = fresh_handler({
    service = { protocol = "http", host = "a.internal", port = 80 },
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128,
                   proxy_username = "kong", proxy_password = "pw" })
  t.equal(state.request.headers["Proxy-Authorization"], "Basic b64(kong:pw)")
end)

t.test("sends no Proxy-Authorization without credentials", function()
  local handler, state = fresh_handler({
    service = { protocol = "http", host = "a.internal", port = 80 },
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128 })
  t.equal(state.request.headers["Proxy-Authorization"], nil)
end)

t.test("answers 502 when the proxy is unreachable", function()
  local handler, state = fresh_handler({
    service = { protocol = "http", host = "a.internal", port = 80 },
    connect_error = "connection refused",
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128 })
  t.equal(state.exit_status, 502)
  t.equal(state.request, nil) -- never sent anything
end)

t.test("rejects an https upstream with 503 by default", function()
  local handler, state = fresh_handler({
    service = { protocol = "https", host = "a.internal", port = 8443 },
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128,
                   on_https = "reject" })
  t.equal(state.exit_status, 503)
  t.equal(state.connected, nil) -- never touched the proxy
end)

t.test("bypasses the proxy for https when configured", function()
  local handler, state = fresh_handler({
    service = { protocol = "https", host = "a.internal", port = 8443 },
    upstream_uri = "/x",
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128,
                   on_https = "bypass" })
  t.equal(state.exit_status, nil)
  t.equal(state.connected, nil)               -- direct connection
  t.equal(ngx.var.upstream_uri, "/x")         -- untouched
end)

t.test("skips a serviceless route with a warning", function()
  local handler, state = fresh_handler({ service = nil })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128 })
  t.truthy(state.warned)
  t.equal(state.connected, nil)
  t.equal(state.exit_status, nil)
end)

return t
