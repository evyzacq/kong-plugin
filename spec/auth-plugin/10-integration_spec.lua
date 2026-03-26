-- spec/auth-plugin/01-integration_spec.lua

local helpers   = require "spec.helpers"
local cjson     = require "cjson.safe"
local http_mock = require "spec.helpers.http_mock"

local PLUGIN_NAME = "auth-plugin"

for _, strategy in helpers.all_strategies() do
  if strategy ~= "cassandra" then
    describe(PLUGIN_NAME .. " integration [#" .. strategy .. "]", function()
      local bp
      local proxy_client
      local mock
      local mock_port

      local function merge(a, b)
        local out = {}
        for k, v in pairs(a or {}) do
          out[k] = v
        end
        for k, v in pairs(b or {}) do
          out[k] = v
        end
        return out
      end

      local function decode_200(res)
        local body = assert.res_status(200, res)
        local json = cjson.decode(body)
        assert.is_table(json)
        return json
      end

      local function assert_upstream_header(res, header_name, expected_value)
        local json = decode_200(res)
        assert.is_table(json.headers)
        assert.equals(expected_value, json.headers[string.lower(header_name)])
        return json
      end

      lazy_setup(function()
        mock, mock_port = http_mock.new(nil, {
          ["/auth"] = {
            access = [[
              local cjson = require "cjson.safe"

              ngx.req.read_body()
              local headers = ngx.req.get_headers()
              local credential = headers["authorization"]

              ngx.header["Content-Type"] = "application/json"

              if credential == nil then
                ngx.status = 401
                ngx.say(cjson.encode({
                  message = "Missing required header: Authorization"
                }))
                return ngx.exit(401)
              end

              if credential == "" then
                ngx.status = 401
                ngx.say(cjson.encode({
                  message = "Empty header value: Authorization"
                }))
                return ngx.exit(401)
              end

              if credential == "Bearer good-token" then
                ngx.status = 200
                ngx.say(cjson.encode({
                  message = "authorized"
                }))
                return ngx.exit(200)
              end

              if credential == "Bearer override-good" then
                ngx.status = 200
                ngx.say(cjson.encode({
                  message = "authorized by override"
                }))
                return ngx.exit(200)
              end

              if credential == "Bearer jwt-seed" then
                ngx.status = 200
                ngx.say(cjson.encode({
                  message = "authorized",
                  jwt = "jwt.from.auth.server"
                }))
                return ngx.exit(200)
              end

              ngx.status = 401
              ngx.say(cjson.encode({
                message = "Unauthorized"
              }))
              return ngx.exit(401)
            ]],
          },

          ["/api"] = {
            access = [[
              local cjson = require "cjson.safe"

              ngx.req.read_body()
              local headers = ngx.req.get_headers()

              ngx.status = 200
              ngx.header["Content-Type"] = "application/json"
              ngx.say(cjson.encode({
                message = "ok",
                headers = headers
              }))
              return ngx.exit(200)
            ]],
          },
        }, {
          log_opts = {
            req = true,
            resp = true,
            resp_body = true,
            err = true,
          }
        })

        mock:start()

        bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "plugins",
        }, {
          PLUGIN_NAME,
        })

        local service = bp.services:insert({
          name     = "echo-service",
          host     = "127.0.0.1",
          port     = tonumber(mock_port),
          protocol = "http",
        })

        local function add_case(host, extra_conf)
          local route = bp.routes:insert({
            hosts      = { host },
            paths      = { "/api" },
            strip_path = false,
            service    = service,
          })

          local conf = merge({
            auth_url                  = "http://127.0.0.1:" .. mock_port .. "/auth",
            header_name               = "Authorization",
            upstream_token_header     = "X-Injected-JWT",
          }, extra_conf)

          bp.plugins:insert({
            name   = PLUGIN_NAME,
            route  = { id = route.id },
            config = conf,
          })
        end

        add_case("missing.test")
        add_case("invalid.test")
        add_case("valid.test")
        add_case("empty.test")

        add_case("override.test", {
          header_value = "Bearer override-good",
        })

        assert(helpers.start_kong({
          database = strategy,
          plugins  = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong(nil, true)
        if mock then
          mock:stop()
        end
      end)

      before_each(function()
        if mock and mock.clean then
          mock:clean()
        end
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then
          proxy_client:close()
        end
      end)

      it("1) Missing header -> 401", function()
        local res = assert(proxy_client:send {
          method = "GET",
          path   = "/api",
          headers = {
            Host = "missing.test",
          }
        })

        assert.response(res).has.status(401)
      end)

      it("2) Invalid credential -> 401", function()
        local res = assert(proxy_client:send {
          method = "GET",
          path   = "/api",
          headers = {
            Host          = "invalid.test",
            Authorization = "Bearer bad-token",
          }
        })

        assert.response(res).has.status(401)
      end)

      it("3) Valid credential -> 200", function()
        local res = assert(proxy_client:send {
          method = "GET",
          path   = "/api",
          headers = {
            Host          = "valid.test",
            Authorization = "Bearer good-token",
          }
        })

        local json = assert_upstream_header(
          res,
          "Authorization",
          "Bearer good-token"
        )
        assert.equals("ok", json.message)
      end)

      it("4) Empty header value -> 401", function()
        local res = assert(proxy_client:send {
          method = "GET",
          path   = "/api",
          headers = {
            Host          = "empty.test",
            Authorization = "",
          }
        })

        assert.response(res).has.status(401)
      end)

      it("5) header_value override", function()
        local res = assert(proxy_client:send {
          method = "GET",
          path   = "/api",
          headers = {
            Host          = "override.test",
            Authorization = "Bearer client-bad-token",
          }
        })

        local json = assert_upstream_header(
          res,
          "Authorization",
          "Bearer client-bad-token"
        )
        assert.equals("ok", json.message)
      end)

    end)
  end
end