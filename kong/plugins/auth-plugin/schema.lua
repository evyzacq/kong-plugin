local typedefs = require "kong.db.schema.typedefs"

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
            auth_url = {
              type = "string",
              required = true,
            },
          },
          -- Required: name of the incoming request header to forward
          {
            header_name = {
              type = "string",
              required = true,
              default = "Authorization",
            },
          },
          -- Extra Credit 1: override the header value sent to the auth server
          {
            header_value = {
              type = "string",
              required = false,
            },
          },
          -- Extra Credit 3: cache successful auth responses for this many seconds (0 = disabled)
          {
            cache_ttl = {
              type = "number",
              required = false,
              default = 0,
              gt = -1,
            },
          },
          -- Extra Credit 4: key in the auth server JSON response that holds a token (e.g. JWT)
          {
            token_key = {
              type = "string",
              required = false,
              default = "token",
            },
          },
          -- Extra Credit 4: header name used to forward the token to the upstream service
          {
            upstream_token_header = {
              type = "string",
              required = false,
            },
          },
          -- Timeout in milliseconds for the auth server request
          {
            timeout = {
              type = "number",
              required = false,
              default = 5000,
              gt = 0,
            },
          },
        },
      },
    },
  },
}
