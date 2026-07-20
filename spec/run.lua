-- Run with:
--   LUA_PATH="./?.lua;./plugins/egress-proxy/?.lua;;" lua spec/run.lua
require "spec.proxy_spec"
require "spec.handler_spec"
require "spec.schema_spec"
require("spec.test_helper").finish()
