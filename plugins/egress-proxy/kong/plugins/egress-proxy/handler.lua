local proxy = require "kong.plugins.egress-proxy.proxy"

-- PRIORITY 50: this must be (nearly) the LAST access-phase plugin, after
-- anything that rewrites the path or target (request-transformer 801,
-- routing plugins, auth), because it captures the final upstream and
-- redirects the connection to the proxy.
local Handler = { VERSION = "0.1.0", PRIORITY = 50 }

local function fail(status, message)
  return kong.response.exit(status, { message = message })
end

function Handler:access(conf)
  local service = kong.router.get_service()
  if not service then
    -- Serviceless route: nothing to proxy.
    kong.log.warn("egress-proxy: route has no service; skipping")
    return
  end

  if service.protocol == "https" then
    -- A forward proxy carries https as a CONNECT tunnel, which nginx's
    -- proxy_pass data path (and therefore a Kong plugin) cannot speak.
    if conf.on_https == "bypass" then
      kong.log.debug("egress-proxy: https upstream, bypassing the proxy")
      return
    end
    kong.log.err("egress-proxy: https upstream needs CONNECT tunneling, ",
                 "which this plugin cannot do; use on_https=bypass or a ",
                 "transparent proxy for https egress")
    return fail(503, "https egress via forward proxy is not supported")
  end

  local absolute = proxy.absolute_target(service, ngx.var.upstream_uri)

  -- Order matters: set_target() may reset upstream state, so the request
  -- line and headers are written after it.
  kong.service.set_target(conf.proxy_host, conf.proxy_port)
  kong.service.request.set_scheme("http") -- the hop TO the proxy is plain
  ngx.var.upstream_uri = absolute

  -- set_target() overwrites ngx.var.upstream_host with the proxy host;
  -- the origin Host must be restored so the proxy and the origin agree
  -- on the target (Kong put the service host there in access.before).
  kong.service.request.set_header("Host", service.host)

  if conf.proxy_username and conf.proxy_username ~= ngx.null then
    kong.service.request.set_header("Proxy-Authorization",
      proxy.basic_auth(conf.proxy_username, conf.proxy_password))
  end
end

return Handler
