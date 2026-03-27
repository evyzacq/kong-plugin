local http  = require "resty.http"
local cjson = require "cjson.safe"

local kong = kong
local fmt  = string.format
local md5  = ngx.md5

local AuthPluginHandler = {
  PRIORITY = 900,
  VERSION  = "0.2.0",
}


-- =========================================================================
-- Build a lookup set from a config set field (cached per config object)
-- =========================================================================
local blocked_sets = setmetatable({}, { __mode = "k" })

local function is_blocked(conf, header_name)
  if not conf.blocked_headers then
    return false
  end
  local set = blocked_sets[conf]
  if not set then
    set = {}
    for _, v in ipairs(conf.blocked_headers) do
      set[v:lower()] = true
    end
    blocked_sets[conf] = set
  end
  return set[header_name:lower()] == true
end


-- =========================================================================
-- Cache key builder
-- Includes auth_url + auth_method + forwarding header name + credential
-- so different extraction configs never collide.
-- =========================================================================
local function cache_key(conf, credential)
  local fwd = conf.header_name or conf.credential_name
  return fmt("auth_plugin:%s",
    md5(conf.auth_url .. ":" .. conf.auth_method .. ":" .. fwd .. ":" .. credential))
end


-- =========================================================================
-- Build a lookup set from the success_codes array (called once per config)
-- =========================================================================
local success_sets = setmetatable({}, { __mode = "k" })

local function is_success(conf, status)
  local set = success_sets[conf]
  if not set then
    set = {}
    for _, code in ipairs(conf.success_codes) do
      set[code] = true
    end
    success_sets[conf] = set
  end
  return set[status] == true
end


-- =========================================================================
-- Resolve a dot-path like "data.access_token" against a table
-- =========================================================================
local function resolve_path(tbl, path)
  for part in path:gmatch("[^%.]+") do
    if type(tbl) ~= "table" then
      return nil
    end
    tbl = tbl[part]
  end
  return tbl
end


-- =========================================================================
-- Trusted credential lookup set (built once per config, weak-keyed)
-- =========================================================================
local trusted_sets = setmetatable({}, { __mode = "k" })

local function is_trusted(conf, credential)
  if not conf.trusted_credentials then
    return false
  end
  local set = trusted_sets[conf]
  if not set then
    set = {}
    for _, v in ipairs(conf.trusted_credentials) do
      set[v] = true
    end
    trusted_sets[conf] = set
  end
  return set[credential] == true
end


-- =========================================================================
-- Credential extraction (header / query / cookie) 
-- =========================================================================
local function extract_credential(conf)
  local src  = conf.credential_source
  local name = conf.credential_name

  if src == "query" then
    local args, err = kong.request.get_query()
    if err then
      kong.log.warn("failed to parse query string: ", err)
      return nil
    end
    local val = args[name]
    if type(val) == "table" then
      kong.log.warn("repeated query parameter '", name, "' not supported")
      return nil
    end
    return val
  end
  -- TODO: cookie
  -- default: header
  return kong.request.get_header(name)
end


-- =========================================================================
-- HTTP call with connection pooling
-- =========================================================================
local function authenticate(conf, credential)
  local httpc = http.new()

  httpc:set_timeouts(conf.connect_timeout, conf.send_timeout, conf.read_timeout)

  local fwd_header = conf.header_name or conf.credential_name

  local res, err = httpc:request_uri(conf.auth_url, {
    method  = conf.auth_method,
    headers = {
      [fwd_header] = credential,
    },
    keepalive_timeout = conf.keepalive_timeout,
    pool_size         = conf.keepalive_pool_size,
  })

  if not res then
    return nil, nil, nil, err
  end

  local body = res.body
  if body and #body > conf.max_body_size then
    body = body:sub(1, conf.max_body_size)
    kong.log.warn("auth response body truncated from ", #res.body,
                  " to ", conf.max_body_size, " bytes")
  end

  return body, res.headers, res.status, nil
end


-- =========================================================================
-- Token extraction from JSON body (supports dot-path: "data.access_token")
-- =========================================================================
local function extract_token(body, token_path)
  if not body or body == "" then
    return nil
  end
  local decoded, err = cjson.decode(body)
  if decoded == nil then
    kong.log.debug("failed to decode auth response body: ", err)
    return nil
  end
  return resolve_path(decoded, token_path)
end


-- =========================================================================
-- Access-phase handler
-- =========================================================================
function AuthPluginHandler:access(conf)
  -- 1. Read the credential
  local credential = conf.header_value or extract_credential(conf)

  if not credential then
    return kong.response.exit(401, {
      message = "Authentication credentials missing",
    })
  end

  -- 2. Trusted identity fast-path — skip auth server entirely
  if is_trusted(conf, credential) then
    kong.log.debug("trusted credential, bypassing auth server")
    return
  end

  -- 3. Caching / direct call
  local use_cache = conf.cache_ttl and conf.cache_ttl > 0
  local body, resp_headers, status

  if use_cache then
    local key = cache_key(conf, credential)
    local cached, cache_err = kong.cache:get(key, { ttl = conf.cache_ttl }, function()
      local b, h, s, call_err = authenticate(conf, credential)
      if call_err then
        return nil, call_err
      end
      -- Cache 2xx and 4xx results.
      -- Do NOT cache 5xx, so transient auth-server failures don't stick.
      if (s >= 200 and s < 300) or (s >= 400 and s < 500) then
        return { body = b, headers = h, status = s }
      end

      -- 5xx or other unexpected statuses are not cached
      return nil, "auth_service_error:" .. s
    end)

    if cached then
      body         = cached.body
      resp_headers = cached.headers
      status       = cached.status
    elseif cache_err and cache_err:find("^auth_failed:") then
      -- The auth call succeeded but returned a non-success status;
      -- extract the status code and fall through to the reject logic.
      -- TODO: configurable
      status = tonumber(cache_err:match("^auth_failed:(%d+)"))
    else
      -- cache_err means the HTTP call itself failed (connection error)
      kong.log.err("auth server unreachable: ", cache_err)
      return kong.response.exit(503, { message = "Auth service unavailable" })
    end
  else
    local call_err
    body, resp_headers, status, call_err = authenticate(conf, credential)
    if call_err then
      kong.log.err("auth server unreachable: ", call_err)
      return kong.response.exit(502, { message = "Auth service unavailable" })
    end
  end

  -- 4. Reject anything that isn't in success_codes
  if not is_success(conf, status) then
    if status >= 500 then
      kong.log.err("auth server returned ", status)
      return kong.response.exit(502, { message = "Auth service error" })
    end
    return kong.response.exit(
      status >= 400 and status < 500 and status or 403,
      { message = "Authentication failed" }
    )
  end

  -- 5. Forward token from auth response body to upstream (dot-path supported)
  if conf.upstream_token_header then
    local token = extract_token(body, conf.token_key)
    if token ~= nil then
      kong.service.request.set_header(conf.upstream_token_header, tostring(token))
    end
  end

  -- 6. Forward specific response headers from auth server to upstream
  if conf.upstream_headers and resp_headers then
    -- Build a lowercased lookup of response headers for case-insensitive
    -- matching (HTTP headers are case-insensitive per RFC 7230).
    local lower_resp = {}
    for k, v in pairs(resp_headers) do
      lower_resp[k:lower()] = v
    end
    for _, name in ipairs(conf.upstream_headers) do
      if not is_blocked(conf, name) then
        local val = lower_resp[name:lower()]
        if val then
          kong.service.request.set_header(name, val)
        end
      else
        kong.log.warn("blocked forwarding of header: ", name)
      end
    end
  end
end


return AuthPluginHandler