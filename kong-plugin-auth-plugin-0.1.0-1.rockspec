package = "kong-plugin-auth-plugin"
version = "0.1.0-1"

supported_platforms = { "linux", "macosx" }

source = {
  url = "git+https://github.com/evyzacq/kong-plugin.git",
  tag = "0.1.0",
}

description = {
  summary  = "Kong plugin that authenticates requests via a remote auth server.",
  homepage = "https://github.com/evyzacq/kong-plugin",
  license  = "MIT",
}

dependencies = {
  "lua >= 5.1",
}

build = {
  type = "builtin",
  modules = {
    ["kong.plugins.auth-plugin.handler"] = "kong/plugins/auth-plugin/handler.lua",
    ["kong.plugins.auth-plugin.schema"]  = "kong/plugins/auth-plugin/schema.lua",
  },
}