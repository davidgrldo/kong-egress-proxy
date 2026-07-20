local typedefs = require "kong.db.schema.typedefs"

local function missing(v)
  return v == nil or v == ngx.null or v == ""
end

return {
  name = "egress-proxy",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { proxy_host = typedefs.host { required = true } },
          { proxy_port = typedefs.port { required = true } },
          { proxy_username = { type = "string" } },
          -- referenceable: supports {vault://...} references, so the
          -- proxy password never has to live in plain declarative config.
          { proxy_password = { type = "string", referenceable = true } },
          { on_https = {
              type = "string",
              default = "reject",
              one_of = { "reject", "bypass" },
          } },
        },
        custom_validator = function(config)
          if not missing(config.proxy_password)
             and missing(config.proxy_username) then
            return nil, "proxy_password requires proxy_username"
          end
          return true
        end,
    } },
  },
}
