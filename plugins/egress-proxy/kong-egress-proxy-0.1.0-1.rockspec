package = "kong-egress-proxy"
version = "0.1.0-1"
source = {
  url = "git+https://github.com/davidgrldo/kong-egress-proxy.git",
  tag = "v0.1.0",
  -- luarocks clones the repo into a directory named after it; source.dir
  -- is relative to that clone's parent, so the repo name stays in the path.
  dir = "kong-egress-proxy/plugins/egress-proxy",
}
description = {
  summary = "Route Kong's upstream traffic through a forward proxy (Squid etc.) — Kong OSS 3.x",
  detailed = [[
An OSS alternative to the Enterprise forward-proxy plugin for the common
"all egress must cross a DMZ proxy" topology: rewrites the request line to
absolute-form (RFC 7230), redirects the connection to the proxy, restores
the origin Host, and supports Proxy-Authorization basic credentials.

HTTP upstreams only: https needs a CONNECT tunnel, which nginx's proxy_pass
data path cannot speak — https services are rejected (default) or bypassed
(on_https=bypass). Named egress-proxy to avoid clashing with the Enterprise
plugin name.
]],
  homepage = "https://github.com/davidgrldo/kong-egress-proxy",
  license = "Apache-2.0",
}
dependencies = {
  "lua >= 5.1",
}
build = {
  type = "builtin",
  modules = {
    ["kong.plugins.egress-proxy.handler"] = "kong/plugins/egress-proxy/handler.lua",
    ["kong.plugins.egress-proxy.proxy"] = "kong/plugins/egress-proxy/proxy.lua",
    ["kong.plugins.egress-proxy.schema"] = "kong/plugins/egress-proxy/schema.lua",
  },
}
