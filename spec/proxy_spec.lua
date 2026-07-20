local t = require "spec.test_helper"

local function fresh_proxy()
  package.loaded["kong.plugins.egress-proxy.proxy"] = nil
  _G.ngx = _G.ngx or {}
  -- Stand-in for ngx.encode_base64, enough for unit tests.
  _G.ngx.encode_base64 = function(s)
    return "b64(" .. s .. ")"
  end
  return require "kong.plugins.egress-proxy.proxy"
end

t.test("builds an absolute-form URI from service and path", function()
  local proxy = fresh_proxy()
  t.equal(proxy.absolute_target({ host = "api.partner.id", port = 8080 },
                                "/v1/orders"),
          "http://api.partner.id:8080/v1/orders")
end)

t.test("omits the default http port", function()
  local proxy = fresh_proxy()
  t.equal(proxy.absolute_target({ host = "api.partner.id", port = 80 }, "/x"),
          "http://api.partner.id/x")
  t.equal(proxy.absolute_target({ host = "api.partner.id" }, "/x"),
          "http://api.partner.id/x")
  t.equal(proxy.authority({ host = "api.partner.id", port = 80 }),
          "api.partner.id")
  t.equal(proxy.authority({ host = "api.partner.id", port = 8080 }),
          "api.partner.id:8080")
end)

t.test("defaults an empty path to /", function()
  local proxy = fresh_proxy()
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 }, ""),
          "http://a.internal/")
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 }, nil),
          "http://a.internal/")
end)

t.test("appends the query string to the absolute URI", function()
  -- The plugin re-sends the request itself, so Kong core's "?args" append
  -- in access.after never reaches the proxy hop; this module owns it.
  local proxy = fresh_proxy()
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 },
                                "/p", "a=1&b=2"),
          "http://a.internal/p?a=1&b=2")
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 }, "/p", ""),
          "http://a.internal/p")
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 }, "/p", nil),
          "http://a.internal/p")
end)

t.test("never doubles a query the path already carries", function()
  local proxy = fresh_proxy()
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 },
                                "/p?x=1", "x=1"),
          "http://a.internal/p?x=1")
end)

t.test("encodes Proxy-Authorization basic credentials", function()
  local proxy = fresh_proxy()
  t.equal(proxy.basic_auth("kong", "s3cret"), "Basic b64(kong:s3cret)")
  t.equal(proxy.basic_auth("kong", nil), "Basic b64(kong:)")
end)

t.test("outbound headers drop hop-by-hop, rebuild Host, add proxy auth", function()
  local proxy = fresh_proxy()
  local out = proxy.outbound_headers({
    ["host"] = "kong.gateway",
    ["connection"] = "keep-alive",
    ["Transfer-Encoding"] = "chunked",
    ["content-length"] = "42",
    ["proxy-authorization"] = "Basic client-supplied",
    ["x-request-id"] = "abc",
  }, "origin.internal", "Basic b64(kong:pw)")
  t.equal(out["Host"], "origin.internal")
  t.equal(out["host"], nil)
  t.equal(out["connection"], nil)
  t.equal(out["Transfer-Encoding"], nil)
  t.equal(out["content-length"], nil)
  t.equal(out["x-request-id"], "abc")
  t.equal(out["Proxy-Authorization"], "Basic b64(kong:pw)")
end)

t.test("outbound headers carry no proxy auth without credentials", function()
  local proxy = fresh_proxy()
  local out = proxy.outbound_headers({ ["x-a"] = "1" }, "origin.internal", nil)
  t.equal(out["Proxy-Authorization"], nil)
  t.equal(out["x-a"], "1")
end)

t.test("response headers drop hop-by-hop and stale framing", function()
  local proxy = fresh_proxy()
  local out = proxy.response_headers({
    ["Connection"] = "keep-alive",
    ["Transfer-Encoding"] = "chunked",
    ["Content-Length"] = "10",
    ["Content-Type"] = "application/json",
    ["Via"] = "1.1 squid",
  })
  t.equal(out["Connection"], nil)
  t.equal(out["Transfer-Encoding"], nil)
  t.equal(out["Content-Length"], nil)
  t.equal(out["Content-Type"], "application/json")
  t.equal(out["Via"], "1.1 squid")
end)

return t
