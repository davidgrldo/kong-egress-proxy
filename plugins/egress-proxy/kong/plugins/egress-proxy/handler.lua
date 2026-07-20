local proxy = require "kong.plugins.egress-proxy.proxy"
local http = require "resty.http"

-- PRIORITY 50: this must be (nearly) the LAST access-phase plugin, after
-- anything that rewrites the path or target (request-transformer 801,
-- routing plugins, auth), because it captures the final upstream and
-- takes over the connection to the proxy.
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

  -- nginx's proxy_pass cannot emit an absolute-form request line: Kong's
  -- template is `proxy_pass $upstream_scheme://kong_upstream$upstream_uri`
  -- and nginx requires the URI part after the literal host to start with
  -- "/" — an absolute URI in ngx.var.upstream_uri fails URL parsing
  -- ("invalid port in upstream"). So the plugin sends this hop itself with
  -- Kong's bundled lua-resty-http (the Enterprise forward-proxy takes the
  -- same road). Consequence: the response is buffered, not streamed.
  local absolute = proxy.absolute_target(service, ngx.var.upstream_uri,
                                         kong.request.get_raw_query())

  local auth
  if conf.proxy_username and conf.proxy_username ~= ngx.null then
    auth = proxy.basic_auth(conf.proxy_username, conf.proxy_password)
  end

  local body, err = kong.request.get_raw_body()
  if err then
    -- ponytail: bodies spooled to a temp file are not forwarded; raise
    -- client_body_buffer_size if large uploads must cross the proxy.
    kong.log.err("egress-proxy: cannot read request body: ", err)
    return fail(413, "request body too large to forward through the proxy")
  end
  if body == "" then
    body = nil
  end

  local httpc = http.new()
  httpc:set_timeouts(service.connect_timeout or 60000,
                     service.write_timeout or 60000,
                     service.read_timeout or 60000)

  local ok
  ok, err = httpc:connect({ scheme = "http",
                            host = conf.proxy_host,
                            port = conf.proxy_port })
  if not ok then
    kong.log.err("egress-proxy: cannot reach proxy ", conf.proxy_host, ":",
                 conf.proxy_port, ": ", err)
    return fail(502, "egress proxy is unreachable")
  end

  local res
  res, err = httpc:request({
    method = kong.request.get_method(),
    path = absolute,
    headers = proxy.outbound_headers(kong.request.get_headers(),
                                     proxy.authority(service), auth),
    body = body,
  })
  if not res then
    kong.log.err("egress-proxy: request via ", conf.proxy_host, ":",
                 conf.proxy_port, " failed: ", err)
    return fail(502, "egress proxy request failed")
  end

  local resp_body
  resp_body, err = res:read_body()
  if err then
    kong.log.err("egress-proxy: reading response via ", conf.proxy_host,
                 " failed: ", err)
    return fail(502, "egress proxy response failed")
  end
  httpc:set_keepalive()

  if resp_body == "" then
    resp_body = nil
  end
  return kong.response.exit(res.status, resp_body,
                            proxy.response_headers(res.headers))
end

return Handler
