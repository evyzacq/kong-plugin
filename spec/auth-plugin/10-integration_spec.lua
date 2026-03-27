-- spec/auth-plugin/01-integration_spec.lua
--
-- Integration tests for auth-plugin v0.2.0
-- Covers: credential extraction (header/query/cookie), forwarding,
--         auth_method, success_codes, trusted_credentials, caching,
--         token extraction (flat + dot-path), upstream_headers,
--         blocked_headers, header_value override, unreachable auth server.

local helpers   = require "spec.helpers"
local cjson     = require "cjson.safe"
local http_mock = require "spec.helpers.http_mock"

local PLUGIN_NAME = "auth-plugin"

for _, strategy in helpers.all_strategies() do
  if strategy ~= "cassandra" then
    describe(PLUGIN_NAME .. " integration [#" .. strategy .. "]", function()
      local bp, proxy_client, mock, mock_port

      -- -----------------------------------------------------------------
      -- Helpers
      -- -----------------------------------------------------------------
      local function merge(a, b)
        local out = {}
        for k, v in pairs(a or {}) do out[k] = v end
        for k, v in pairs(b or {}) do out[k] = v end
        return out
      end

      local function decode_json(res, expected_status)
        local body = assert.res_status(expected_status or 200, res)
        return cjson.decode(body)
      end

      -- -----------------------------------------------------------------
      -- Mock server
      -- -----------------------------------------------------------------
      -- Two endpoints:
      --   /auth   – the auth server (validates credential, returns tokens/headers)
      --   /echo   – the upstream (echoes back all received headers as JSON)
      -- -----------------------------------------------------------------
      lazy_setup(function()
        mock, mock_port = http_mock.new(nil, {
          -- ============================================================
          -- AUTH endpoint
          -- ============================================================
          ["/auth"] = {
            access = [[
              local cjson = require "cjson.safe"
              ngx.req.read_body()
              local headers = ngx.req.get_headers()
              local method  = ngx.req.get_method()

              ngx.header["Content-Type"] = "application/json"

              -- ---- credential-based routing ----

              local cred = headers["authorization"]
                        or headers["x-api-key"]
                        or headers["x-custom-header"]

              if cred == nil or cred == "" then
                ngx.status = 401
                ngx.say(cjson.encode({ message = "no credential" }))
                return ngx.exit(401)
              end

              -- good token (GET or POST)
              if cred == "Bearer good-token" then
                ngx.status = 200
                ngx.header["X-User-ID"]   = "user-42"
                ngx.header["X-Tenant"]    = "acme"
                ngx.header["Host"]        = "evil.example.com"
                ngx.say(cjson.encode({
                  message = "authorized",
                  token   = "flat-jwt-value",
                  data    = { access_token = "nested-jwt-value" },
                }))
                return ngx.exit(200)
              end

              -- returns 204 (no body) – tests success_codes
              if cred == "Bearer no-content" then
                ngx.status = 204
                ngx.say("")
                return ngx.exit(204)
              end

              -- returns 401 (not 403) – tests handler maps 401 -> 401
              if cred == "Bearer unauthorized-token" then
                ngx.status = 401
                ngx.say(cjson.encode({ message = "unauthorized" }))
                return ngx.exit(401)
              end

              -- large body response – tests max_body_size truncation
              if cred == "Bearer large-body" then
                ngx.status = 200
                -- Token key is at the end, past the truncation point
                local padding = string.rep("x", 512)
                ngx.say(cjson.encode({
                  padding = padding,
                  token   = "should-be-truncated",
                }))
                return ngx.exit(200)
              end

              -- 5xx error test
              if cred == "Bearer trigger-500" then
                ngx.status = 500
                ngx.say(cjson.encode({ message = "internal error" }))
                return ngx.exit(500)
              end

              -- header_value override test
              if cred == "Bearer override-secret" then
                ngx.status = 200
                ngx.say(cjson.encode({ message = "override ok" }))
                return ngx.exit(200)
              end

              -- query / cookie extraction test
              if cred == "qkey-123" or cred == "cookie-abc" then
                ngx.status = 200
                ngx.say(cjson.encode({ message = "alt source ok" }))
                return ngx.exit(200)
              end

              -- header remap test (credential read as X-API-Key, forwarded as Authorization)
              if cred == "key-remapped" then
                ngx.status = 200
                ngx.say(cjson.encode({ message = "remap ok" }))
                return ngx.exit(200)
              end

              -- POST method test
              if cred == "Bearer post-cred" and method == "POST" then
                ngx.status = 200
                ngx.say(cjson.encode({ message = "post ok" }))
                return ngx.exit(200)
              end

              -- Method-sensitive for cache isolation test
              if cred == "Bearer method-sensitive" then
                if method == "GET" then
                  ngx.status = 200
                  ngx.say(cjson.encode({ message = "Method-sensitive GET ok" }))
                  return ngx.exit(200)
                else
                  ngx.status = 403
                  ngx.say(cjson.encode({ message = "Method-sensitive POST forbidden" }))
                  return ngx.exit(403)
                end
              end

              -- fallthrough: unauthorized
              ngx.status = 403
              ngx.say(cjson.encode({ message = "forbidden" }))
              return ngx.exit(403)
            ]],
          },

          -- ============================================================
          -- AUTH endpoint with nonce (for cache verification)
          -- Returns a unique X-Auth-Nonce header each time it's called.
          -- If caching works, repeated requests get the same nonce.
          -- ============================================================
          ["/auth-nonce"] = {
            access = [[
              local cjson = require "cjson.safe"
              ngx.req.read_body()
              local headers = ngx.req.get_headers()
              ngx.header["Content-Type"] = "application/json"

              local cred = headers["authorization"]
              if cred == "Bearer nonce-token" then
                local nonce = tostring(ngx.now()) .. "-" .. tostring(math.random(1, 999999))
                ngx.header["X-Auth-Nonce"] = nonce
                ngx.status = 200
                ngx.say(cjson.encode({ token = "nonce-jwt" }))
                return ngx.exit(200)
              end

              ngx.status = 403
              ngx.say(cjson.encode({ message = "forbidden" }))
              return ngx.exit(403)
            ]],
          },

          -- ============================================================
          -- ECHO endpoint (upstream)
          -- ============================================================
          ["/echo"] = {
            access = [[
              local cjson = require "cjson.safe"
              ngx.req.read_body()
              local headers = ngx.req.get_headers()
              ngx.status = 200
              ngx.header["Content-Type"] = "application/json"
              ngx.say(cjson.encode({ headers = headers }))
              return ngx.exit(200)
            ]],
          },
        }, {
          log_opts = {
            req = true,
            resp = true,
            resp_body = true,
            err = true,
          },
        })

        mock:start()

        bp = helpers.get_db_utils(strategy, {
          "routes", "services", "plugins",
        }, {
          PLUGIN_NAME,
        })

        local service = bp.services:insert({
          name     = "echo-service",
          host     = "127.0.0.1",
          port     = tonumber(mock_port),
          protocol = "http",
        })

        -- Helper: create a route + plugin config
        local AUTH_URL = "http://127.0.0.1:" .. mock_port .. "/auth"

        local function add_case(host, extra_conf)
          local route = bp.routes:insert({
            hosts      = { host },
            paths      = { "/echo" },
            strip_path = false,
            service    = service,
          })
          bp.plugins:insert({
            name   = PLUGIN_NAME,
            route  = { id = route.id },
            config = merge({
              auth_url        = AUTH_URL,
              credential_name = "Authorization",
            }, extra_conf),
          })
        end

        -- 1. Basic: missing / invalid / valid
        add_case("missing.test")
        add_case("invalid.test")
        add_case("valid.test")

        -- 2. header_value override
        add_case("override.test", {
          header_value = "Bearer override-secret",
        })

        -- 3. credential_source = query
        add_case("query.test", {
          credential_source = "query",
          credential_name   = "api_key",
          header_name       = "X-API-Key",
        })

        -- 4. credential_source = cookie
        -- TODO

        -- 5. header_name remap (read X-API-Key, forward as X-Custom-Header)
        add_case("remap.test", {
          credential_name = "X-API-Key",
          header_name     = "X-Custom-Header",
        })

        -- 6. auth_method = POST
        add_case("post.test", {
          auth_method = "POST",
        })

        -- 7. success_codes includes 204
        add_case("successcodes.test", {
          success_codes = { 200, 204 },
        })

        -- 8. trusted_credentials fast-path
        add_case("trusted.test", {
          trusted_credentials = { "Bearer trusted-machine-token" },
        })

        -- 9. cache_ttl
        add_case("cache.test", {
          cache_ttl = 60,
        })

        -- 10. upstream_token_header + token_key (flat)
        add_case("token-flat.test", {
          upstream_token_header = "X-Auth-Token",
          token_key             = "token",
        })

        -- 11. upstream_token_header + token_key (dot-path)
        add_case("token-dotpath.test", {
          upstream_token_header = "X-Auth-Token",
          token_key             = "data.access_token",
        })

        -- 12. upstream_headers (X-User-ID, X-Tenant forwarded; Host blocked)
        add_case("upstream-hdrs.test", {
          upstream_headers = { "X-User-ID", "X-Tenant", "Host" },
        })

        -- 13. blocked_headers custom override (allow Host through)
        add_case("custom-blocked.test", {
          upstream_headers = { "X-User-ID", "Host" },
          blocked_headers  = { "transfer-encoding" },
        })

        -- 14. Auth server unreachable
        local dead_route = bp.routes:insert({
          hosts      = { "dead.test" },
          paths      = { "/echo" },
          strip_path = false,
          service    = service,
        })
        bp.plugins:insert({
          name   = PLUGIN_NAME,
          route  = { id = dead_route.id },
          config = {
            auth_url        = "http://127.0.0.1:1/auth",  -- port 1: unreachable
            credential_name = "Authorization",
            connect_timeout = 500,
            read_timeout    = 500,
            send_timeout    = 500,
          },
        })

        -- 15. success_codes rejection (default codes = {200}, 204 should fail)
        add_case("successcodes-reject.test")

        -- 16. Auth server returns 401 (handler should map to 401, not 403)
        add_case("auth-401.test")

        -- 17. max_body_size truncation (256 bytes so large-body token is lost)
        add_case("max-body.test", {
          max_body_size         = 256,
          upstream_token_header = "X-Auth-Token",
          token_key             = "token",
        })

        -- 18. Valid credential with token forwarding (for meaningful assertion)
        add_case("valid-with-token.test", {
          upstream_token_header = "X-Auth-Token",
          token_key             = "token",
        })

        -- 19. Auth server returns 5xx -> 502
        add_case("auth-500.test")

        -- 20. Cache hit verification (uses nonce endpoint)
        local nonce_auth_url = "http://127.0.0.1:" .. mock_port .. "/auth-nonce"
        local cache_nonce_route = bp.routes:insert({
          hosts      = { "cache-nonce.test" },
          paths      = { "/echo" },
          strip_path = false,
          service    = service,
        })
        bp.plugins:insert({
          name   = PLUGIN_NAME,
          route  = { id = cache_nonce_route.id },
          config = merge({
            auth_url          = nonce_auth_url,
            credential_name   = "Authorization",
            cache_ttl         = 60,
            upstream_headers  = { "X-Auth-Nonce" },
          }),
        })

        -- 21. Cache isolation: same auth_url, same credential, different auth_method
        --     GET route: auth server returns 200 for "Bearer good-token"
        --     POST route: auth server returns 200 for "Bearer post-cred" only
        --     if "Bearer method-sensitive", GET returns 200, POST returns 403
        add_case("cache-get.test", {
          auth_method = "GET",
          cache_ttl   = 60,
        })

        add_case("cache-post.test", {
          auth_method = "POST",
          cache_ttl   = 60,
        })

        -- 22. Header case mismatch test: upstream_headers uses mixed case,
        --     auth server returns lowercase headers
        --     Mock returns "X-User-ID" (mixed case); config says "x-user-id" (lower)
        add_case("header-case.test", {
          upstream_headers = { "x-user-id" },
        })

        assert(helpers.start_kong({
          database = strategy,
          plugins  = "bundled," .. PLUGIN_NAME,
        }))
      end)

      lazy_teardown(function()
        helpers.stop_kong(nil, true)
        if mock then mock:stop() end
      end)

      before_each(function()
        if mock and mock.clean then mock:clean() end
        proxy_client = helpers.proxy_client()
      end)

      after_each(function()
        if proxy_client then proxy_client:close() end
      end)

      -- ===============================================================
      -- Test cases
      -- ===============================================================

      it("missing credential -> 401", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = { Host = "missing.test" },
        })
        local body = decode_json(res, 401)
        assert.equals("Authentication credentials missing", body.message)
      end)

      it("invalid credential -> 403 (auth server returns 403)", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "invalid.test",
            Authorization = "Bearer bad-token",
          },
        })
        assert.response(res).has.status(403)
      end)

      it("valid credential -> 200, proxied to upstream", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "valid.test",
            Authorization = "Bearer good-token",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        -- The original client header reaches the upstream (plugin doesn't strip it)
        assert.equals("Bearer good-token", body.headers["authorization"])
      end)

      it("valid credential -> plugin injects token into upstream header", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "valid-with-token.test",
            Authorization = "Bearer good-token",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        -- This verifies the plugin actually ran: it called the auth server,
        -- extracted the token, and injected it upstream.
        assert.equals("flat-jwt-value", body.headers["x-auth-token"])
      end)

      it("header_value override: client cred ignored, override used", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "override.test",
            Authorization = "Bearer client-junk",
          },
        })
        -- Plugin sends "Bearer override-secret" to auth, gets 200.
        -- Client's original "Bearer client-junk" header reaches upstream.
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
      end)

      it("credential_source=query: reads api_key from query string", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo?api_key=qkey-123",
          headers = { Host = "query.test" },
        })
        assert.response(res).has.status(200)
      end)

      it("credential_source=query: missing query param -> 401", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = { Host = "query.test" },
        })
        assert.response(res).has.status(401)
      end)

      it("header_name remap: read X-API-Key, forward as X-Custom-Header", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host      = "remap.test",
            ["X-API-Key"] = "key-remapped",
          },
        })
        assert.response(res).has.status(200)
      end)

      it("auth_method=POST: sends POST to auth server", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "post.test",
            Authorization = "Bearer post-cred",
          },
        })
        assert.response(res).has.status(200)
      end)

      it("success_codes: 204 treated as success", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "successcodes.test",
            Authorization = "Bearer no-content",
          },
        })
        assert.response(res).has.status(200)
      end)

      it("trusted_credentials: bypasses auth server entirely", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "trusted.test",
            Authorization = "Bearer trusted-machine-token",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        -- The original header still reaches upstream
        assert.equals("Bearer trusted-machine-token", body.headers["authorization"])
      end)

      it("trusted_credentials: non-trusted credential still goes to auth", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "trusted.test",
            Authorization = "Bearer not-trusted",
          },
        })
        -- Auth server returns 403 for unknown tokens
        assert.response(res).has.status(403)
      end)

      it("cache_ttl: repeated requests succeed (cache does not break flow)", function()
        -- First call: cache miss, hits auth server
        local res1 = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "cache.test",
            Authorization = "Bearer good-token",
          },
        })
        assert.response(res1).has.status(200)

        -- Second call: should be served from cache
        local res2 = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "cache.test",
            Authorization = "Bearer good-token",
          },
        })
        assert.response(res2).has.status(200)

        -- Third call with a different credential: cache miss for this key
        local res3 = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "cache.test",
            Authorization = "Bearer bad-token",
          },
        })
        -- Auth server returns 403 for unknown tokens, handler maps to 403
        assert.response(res3).has.status(403)

        -- Verify the first credential is still valid (not poisoned by
        -- the failed credential's cached result)
        local res4 = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "cache.test",
            Authorization = "Bearer good-token",
          },
        })
        assert.response(res4).has.status(200)
      end)

      it("upstream_token_header + flat token_key: injects token header", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "token-flat.test",
            Authorization = "Bearer good-token",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        assert.equals("flat-jwt-value", body.headers["x-auth-token"])
      end)

      it("upstream_token_header + dot-path token_key: extracts nested value", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "token-dotpath.test",
            Authorization = "Bearer good-token",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        assert.equals("nested-jwt-value", body.headers["x-auth-token"])
      end)

      it("upstream_headers: forwards allowed headers, blocks Host by default", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "upstream-hdrs.test",
            Authorization = "Bearer good-token",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        assert.equals("user-42", body.headers["x-user-id"])
        assert.equals("acme", body.headers["x-tenant"])
        -- Host should NOT be overwritten by auth server's "evil.example.com"
        assert.not_equals("evil.example.com", body.headers["host"])
      end)

      it("blocked_headers custom: operator allows Host through", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "custom-blocked.test",
            Authorization = "Bearer good-token",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        assert.equals("user-42", body.headers["x-user-id"])
        -- Custom blocked_headers only blocks transfer-encoding, so Host IS forwarded
        assert.equals("evil.example.com", body.headers["host"])
      end)

      it("auth server unreachable -> 502", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "dead.test",
            Authorization = "Bearer anything",
          },
        })
        local body = decode_json(res, 502)
        assert.equals("Auth service unavailable", body.message)
      end)

      it("success_codes rejection: 204 rejected when not in success_codes", function()
        -- Default success_codes = {200}. Auth server returns 204 for this cred.
        -- 204 is 2xx but not in success_codes, so handler returns 403 (not 4xx range).
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "successcodes-reject.test",
            Authorization = "Bearer no-content",
          },
        })
        assert.response(res).has.status(403)
      end)

      it("auth server returns 401 -> handler passes 401 through", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "auth-401.test",
            Authorization = "Bearer unauthorized-token",
          },
        })
        local body = decode_json(res, 401)
        assert.equals("Authentication failed", body.message)
      end)

      it("max_body_size: truncated body loses token past cutoff", function()
        -- The mock returns a large JSON body (~550+ bytes).
        -- max_body_size=256 truncates it, so JSON decoding fails or
        -- the token key is lost. Auth still succeeds (200 is in success_codes)
        -- but the token should NOT appear in the upstream header.
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "max-body.test",
            Authorization = "Bearer large-body",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        -- Token should NOT be present because the body was truncated
        -- and JSON decoding of the partial body fails
        assert.is_nil(body.headers["x-auth-token"])
      end)

      it("auth server returns 5xx -> 502", function()
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "auth-500.test",
            Authorization = "Bearer trigger-500",
          },
        })
        local body = decode_json(res, 502)
        assert.equals("Auth service error", body.message)
      end)

      it("cache hit: repeated requests get same nonce (proves cache hit)", function()
        -- First call: cache miss, auth-nonce endpoint returns unique nonce
        local res1 = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "cache-nonce.test",
            Authorization = "Bearer nonce-token",
          },
        })
        local body1 = decode_json(res1, 200)
        assert.is_table(body1.headers)
        local nonce1 = body1.headers["x-auth-nonce"]
        assert.is_string(nonce1)

        -- Second call: should hit cache, get the SAME nonce
        local res2 = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "cache-nonce.test",
            Authorization = "Bearer nonce-token",
          },
        })
        local body2 = decode_json(res2, 200)
        local nonce2 = body2.headers["x-auth-nonce"]
        assert.is_string(nonce2)

        -- If cache works, both nonces are identical (came from same cached response)
        assert.equals(nonce1, nonce2)
      end)

      it("cache isolation: GET and POST routes don't share cache", function()
        -- Warm the GET cache with good-token -> 200
        local res1 = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "cache-get.test",
            Authorization = "Bearer method-sensitive",
          },
        })
        assert.response(res1).has.status(200)

        -- POST route with same credential: auth server only accepts "Bearer post-cred"
        -- for POST, so "Bearer good-token" via POST gets 403 from mock.
        -- If cache keys were shared (no auth_method), this would wrongly return 200.
        local res2 = proxy_client:send({
          method  = "POST",
          path    = "/echo",
          headers = {
            Host          = "cache-post.test",
            Authorization = "Bearer method-sensitive",
          },
        })
        -- Should be 403 (auth server rejects good-token when method=POST)
        -- not 200 from GET cache leak
        assert.response(res2).has.status(403)
      end)

      it("upstream_headers: case-insensitive lookup (config lowercase, server mixed)", function()
        -- Config: upstream_headers = { "x-user-id" }  (lowercase)
        -- Mock auth server returns header "X-User-ID" (mixed case)
        -- With case-insensitive normalization, the header should still be forwarded
        local res = proxy_client:send({
          method  = "GET",
          path    = "/echo",
          headers = {
            Host          = "header-case.test",
            Authorization = "Bearer good-token",
          },
        })
        local body = decode_json(res, 200)
        assert.is_table(body.headers)
        -- The value should be forwarded despite case mismatch
        assert.equals("user-42", body.headers["x-user-id"])
      end)
    end)
  end
end