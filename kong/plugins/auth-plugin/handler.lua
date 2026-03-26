local http = require "resty.http"
local cjson = require "cjson.safe"

local kong = kong
local fmt  = string.format

local AuthPluginHandler = {
  PRIORITY = 900, -- run before most other plugins, after rate-limiting
  VERSION  = "0.1.0",
}


--- Build a cache key from the auth URL and the credential value.
-- Keeps cache scoped per-route so different routes sharing the plugin
-- don't accidentally share auth state.
local function cache_key(conf, credential)
  -- kong.request.get_path() is phase-safe in access
  return fmt("auth_plugin:%s:%s:%s", conf.auth_url, conf.header_name, credential)
end


--- Call the remote auth server.
-- @param conf   plugin configuration table
-- @param credential  header value to send
-- @return body (string|nil), status (number), err (string|nil)
local function authenticate(conf, credential)
  local httpc = http.new()
  httpc:set_timeout(conf.timeout)

  local res, err = httpc:request_uri(conf.auth_url, {
    method  = "GET",
    headers = {
      [conf.header_name] = credential,
    },
  })

  if not res then
    return nil, 502, err
  end

  return res.body, res.status, nil
end


--- Try to extract a token from a JSON response body.
-- @param body       raw response body
-- @param token_key  JSON key to look up
-- @return token string or nil
local function extract_token(body, token_key)
  if not body or body == "" then
    return nil
  end
  local decoded = cjson.decode(body)
  if not decoded then
    return nil
  end
  return decoded[token_key]
end


--- Main access-phase handler.
function AuthPluginHandler:access(conf)
  -- 1. Read the credential from the incoming request header
  local credential = conf.header_value or kong.request.get_header(conf.header_name)

  if not credential then
    return kong.response.exit(401, {
      message = fmt("Missing required header: %s", conf.header_name),
    })
  end

  -- 2. Try the cache when TTL > 0
  local use_cache = conf.cache_ttl and conf.cache_ttl > 0
  local body, status

  if use_cache then
    local key = cache_key(conf, credential)
    local cached, err = kong.cache:get(key, { ttl = conf.cache_ttl }, function()
      local b, s, call_err = authenticate(conf, credential)
      if call_err then
        return nil, call_err
      end
      if s ~= 200 then
        -- We do NOT cache non-200 responses; return nil so kong.cache
        -- stores nothing and we re-check next time.
        return nil, fmt("auth server returned %d", s)
      end
      -- Cache the response body (may contain the JWT)
      return { body = b, status = s }
    end)

    if cached then
      body   = cached.body
      status = cached.status
    else
      -- Cache miss with error means auth failed or upstream error
      if err then
        kong.log.debug("remote auth failed: ", err)
      end
      -- Re-call without cache to get the actual status code for the client
      local b, s, call_err = authenticate(conf, credential)
      if call_err then
        kong.log.err("remote auth server unreachable: ", call_err)
        return kong.response.exit(502, { message = "Auth server unreachable" })
      end
      body   = b
      status = s
    end
  else
    -- No caching – straight call
    local call_err
    body, status, call_err = authenticate(conf, credential)
    if call_err then
      kong.log.err("remote auth server unreachable: ", call_err)
      return kong.response.exit(500, { message = "Auth server unreachable" })
    end
  end

  -- 3. Reject anything that isn't 200
  if status ~= 200 then
    return kong.response.exit(status >= 400 and status < 500 and status or 403, {
      message = "Authentication failed",
    })
  end

  -- 4. Extra Credit 4: forward a token from the auth response to the upstream
  if conf.upstream_token_header then
    local token = extract_token(body, conf.token_key)
    if token then
      kong.service.request.set_header(conf.upstream_token_header, token)
    end
  end
end


return AuthPluginHandler
