local typedefs = require "kong.db.schema.typedefs"

-- Custom validator: when header_name is nil the handler uses credential_name
-- as the HTTP header to forward.  Dots are invalid in HTTP header names, so
-- reject the combination credential_name-with-dot + no header_name.
local function validate_forwarding_header(config)
  if config.header_name == nil or config.header_name == ngx.null then
    if config.credential_name and config.credential_name:find(".", 1, true) then
      return nil, "credential_name contains a dot ('" .. config.credential_name
                .. "') which is invalid in HTTP header names; "
                .. "set header_name to an explicit dot-free value"
    end
  end
  return true
end

return {
  name = "auth-plugin",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    {
      config = {
        type = "record",
        fields = {
          -- Required: URL of the remote authentication server
          {
            auth_url = typedefs.url {
              required = true,
            },
          },
          -- HTTP method used when calling the auth server
          {
            auth_method = {
              type = "string",
              required = false,
              default = "GET",
              one_of = { "GET", "POST", "PUT", "HEAD" },
            },
          },

          -- ---------------------------------------------------------------
          -- Credential extraction
          -- ---------------------------------------------------------------
          -- Where to read the credential from the incoming request
          {
            credential_source = {
              type = "string",
              required = false,
              default = "header",
              one_of = { "header", "query", "cookie" },
            },
          },
          -- Name of the header / query param / cookie to read
          {
            credential_name = {
              type = "string",
              required = true,
              default = "Authorization",
              len_min = 1,
              len_max = 256,
              match = "^[A-Za-z0-9%-_%.]+$",
            },
          },

          -- ---------------------------------------------------------------
          -- Credential forwarding to auth server
          -- ---------------------------------------------------------------
          -- Header name used when forwarding credential to the auth server
          -- (defaults to credential_name if not set)
          {
            header_name = {
              type = "string",
              required = false,
              len_min = 1,
              len_max = 256,
              match = "^[A-Za-z0-9%-_]+$",
            },
          },
          -- Override the credential value sent to the auth server
          -- Marked encrypted so Kong stores it via its Vault / keyring
          {
            header_value = {
              type = "string",
              required = false,
              encrypted = true,
              referenceable = true,
            },
          },

          -- ---------------------------------------------------------------
          -- Success criteria
          -- ---------------------------------------------------------------
          -- Set of HTTP status codes that mean "auth succeeded"
          {
            success_codes = {
              type = "set",
              required = false,
              default = { 200 },
              len_min = 1,
              elements = {
                type = "integer",
                between = { 200, 299 },
              },
            },
          },

          -- ---------------------------------------------------------------
          -- Trusted identity fast-path (skip auth server call entirely)
          -- If the extracted credential matches any value in this list,
          -- the request is allowed through without calling auth_url.
          -- Like NFS trusted-host exports — zero latency for known
          -- machine accounts, service tokens, health-check probes.
          -- Values are encrypted at rest (Vault / keyring).
          -- ---------------------------------------------------------------
          {
            trusted_credentials = {
              type = "set",
              required = false,
              elements = {
                type = "string",
                len_min = 1,
                encrypted = true,
                referenceable = true,
              },
            },
          },

          -- ---------------------------------------------------------------
          -- Timeout configuration (split connect / read / send)
          -- ---------------------------------------------------------------
          {
            connect_timeout = {
              type = "integer",
              required = false,
              default = 2000,
              between = { 1, 30000 },
            },
          },
          {
            read_timeout = {
              type = "integer",
              required = false,
              default = 5000,
              between = { 1, 60000 },
            },
          },
          {
            send_timeout = {
              type = "integer",
              required = false,
              default = 5000,
              between = { 1, 60000 },
            },
          },

          -- ---------------------------------------------------------------
          -- Connection pooling
          -- ---------------------------------------------------------------
          {
            keepalive_timeout = {
              type = "integer",
              required = false,
              default = 60000,
              between = { 0, 300000 },
            },
          },
          {
            keepalive_pool_size = {
              type = "integer",
              required = false,
              default = 60,
              between = { 1, 1000 },
            },
          },

          -- ---------------------------------------------------------------
          -- Caching (success only; failures are never cached so
          -- transient errors don't stick for the full TTL)
          -- ---------------------------------------------------------------
          {
            cache_ttl = {
              type = "integer",
              required = false,
              default = 0,
              between = { 0, 86400 },
            },
          },

          -- ---------------------------------------------------------------
          -- Response body safety
          -- ---------------------------------------------------------------
          {
            max_body_size = {
              type = "integer",
              required = false,
              default = 65536,
              between = { 256, 1048576 },
            },
          },

          -- ---------------------------------------------------------------
          -- Token forwarding to upstream
          -- ---------------------------------------------------------------
          {
            token_key = {
              type = "string",
              required = false,
              default = "token",
              len_min = 1,
              match = "^[A-Za-z0-9%-_%.]+$",
            },
          },
          {
            upstream_token_header = {
              type = "string",
              required = false,
              len_min = 1,
              len_max = 256,
              match = "^[A-Za-z0-9%-_]+$",
            },
          },
          -- Forward specific response headers from auth server to upstream
          {
            upstream_headers = {
              type = "set",
              required = false,
              elements = {
                type = "string",
                len_min = 1,
                len_max = 256,
                match = "^[A-Za-z0-9%-_]+$",
              },
            },
          },
          -- Headers blocked from forwarding (hop-by-hop / request-smuggling)
          -- Safe default provided; operators can override for special cases.
          -- Values must be lowercase (handler compares case-insensitively).
          {
            blocked_headers = {
              type = "set",
              required = false,
              default = {
                "host",
                "transfer-encoding",
                "content-length",
                "content-encoding",
                "connection",
                "upgrade",
                "proxy-authenticate",
                "proxy-authorization",
                "te",
                "trailer",
              },
              elements = {
                type = "string",
                len_min = 1,
                len_max = 256,
                match = "^[a-z0-9%-]+$",
              },
            },
          },
        },
        entity_checks = {
          { custom_entity_check = {
              field_sources = { "credential_name", "header_name" },
              fn = validate_forwarding_header,
          }},
        },
      },
    },
  },
}