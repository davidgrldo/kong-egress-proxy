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
end)

t.test("defaults an empty path to /", function()
  local proxy = fresh_proxy()
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 }, ""),
          "http://a.internal/")
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 }, nil),
          "http://a.internal/")
end)

t.test("never appends a query string itself", function()
  -- Kong core appends "?args" in access.after; the module must pass the
  -- path through untouched so the query isn't doubled.
  local proxy = fresh_proxy()
  t.equal(proxy.absolute_target({ host = "a.internal", port = 80 },
                                "/p"), "http://a.internal/p")
end)

t.test("encodes Proxy-Authorization basic credentials", function()
  local proxy = fresh_proxy()
  t.equal(proxy.basic_auth("kong", "s3cret"), "Basic b64(kong:s3cret)")
  t.equal(proxy.basic_auth("kong", nil), "Basic b64(kong:)")
end)

return t
