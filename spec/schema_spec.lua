local t = require "spec.test_helper"

package.loaded["kong.db.schema.typedefs"] = setmetatable({
  no_consumer = { type = "foreign" },
  protocols_http = { type = "set" },
}, { __index = function()
  return function(tbl) return tbl end -- typedefs.host{...} / port{...}
end })
_G.ngx = _G.ngx or {}
_G.ngx.null = _G.ngx.null or {}

package.loaded["kong.plugins.egress-proxy.schema"] = nil
local schema = require "kong.plugins.egress-proxy.schema"

local validate
for _, f in ipairs(schema.fields) do
  if f.config then validate = f.config.custom_validator end
end

t.test("accepts credentials together, or username alone", function()
  t.truthy(validate({ proxy_username = "kong", proxy_password = "pw" }))
  t.truthy(validate({ proxy_username = "kong" }))
  t.truthy(validate({}))
end)

t.test("rejects a password without a username", function()
  local ok, err = validate({ proxy_password = "pw" })
  t.falsy(ok)
  t.equal(err, "proxy_password requires proxy_username")
  t.falsy(validate({ proxy_password = "pw", proxy_username = ngx.null }))
end)

return t
