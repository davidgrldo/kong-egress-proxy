local t = require "spec.test_helper"

-- Full-mock harness: capture every side effect the handler produces.
local function fresh_handler(opts)
  package.loaded["kong.plugins.egress-proxy.handler"] = nil
  package.loaded["kong.plugins.egress-proxy.proxy"] = nil

  local state = {
    headers = {}, target = nil, scheme = nil,
    exit_status = nil, warned = false,
  }

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
    response = {
      exit = function(_, status) state.exit_status = status end,
    },
    service = {
      set_target = function(host, port) state.target = host .. ":" .. port end,
      request = {
        set_scheme = function(s) state.scheme = s end,
        set_header = function(k, v) state.headers[k] = v end,
      },
    },
  }
  -- kong.response.exit(status, body): first arg is status here (no self).
  _G.kong.response.exit = function(status) state.exit_status = status end

  return require "kong.plugins.egress-proxy.handler", state
end

t.test("routes an http upstream through the proxy in absolute form", function()
  local handler, state = fresh_handler({
    service = { protocol = "http", host = "api.partner.id", port = 8080 },
    upstream_uri = "/v1/orders",
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128 })
  t.equal(state.target, "squid.dmz:3128")
  t.equal(state.scheme, "http")
  t.equal(ngx.var.upstream_uri, "http://api.partner.id:8080/v1/orders")
  t.equal(state.headers["Host"], "api.partner.id")
  t.equal(state.exit_status, nil)
end)

t.test("sets Proxy-Authorization when credentials are configured", function()
  local handler, state = fresh_handler({
    service = { protocol = "http", host = "a.internal", port = 80 },
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128,
                   proxy_username = "kong", proxy_password = "pw" })
  t.equal(state.headers["Proxy-Authorization"], "Basic b64(kong:pw)")
end)

t.test("sends no Proxy-Authorization without credentials", function()
  local handler, state = fresh_handler({
    service = { protocol = "http", host = "a.internal", port = 80 },
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128 })
  t.equal(state.headers["Proxy-Authorization"], nil)
end)

t.test("rejects an https upstream with 503 by default", function()
  local handler, state = fresh_handler({
    service = { protocol = "https", host = "a.internal", port = 8443 },
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128,
                   on_https = "reject" })
  t.equal(state.exit_status, 503)
  t.equal(state.target, nil) -- never touched the balancer
end)

t.test("bypasses the proxy for https when configured", function()
  local handler, state = fresh_handler({
    service = { protocol = "https", host = "a.internal", port = 8443 },
    upstream_uri = "/x",
  })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128,
                   on_https = "bypass" })
  t.equal(state.exit_status, nil)
  t.equal(state.target, nil)                  -- direct connection
  t.equal(ngx.var.upstream_uri, "/x")         -- untouched
end)

t.test("skips a serviceless route with a warning", function()
  local handler, state = fresh_handler({ service = nil })
  handler:access({ proxy_host = "squid.dmz", proxy_port = 3128 })
  t.truthy(state.warned)
  t.equal(state.target, nil)
  t.equal(state.exit_status, nil)
end)

return t
