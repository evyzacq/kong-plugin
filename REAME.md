# kong-plugin-auth-plugin

A Kong Gateway authentication plugin that delegates credential validation to a remote HTTP server. 
If the remote server returns **200 OK** the request is proxied; any other status is forwarded to the client as a **40x** error. 

## Features 
| Feature | Status | 
|---|---|
| Forward a request header to a remote auth server | Core |
| Configurable auth server URL | Core |
| Configurable request header name | Core |
| Configurable (override) header value | Extra Credit |
| Cache auth responses with configurable TTL | Extra Credit |
| Extract a token (JWT) from the auth response and forward it upstream | Extra Credit |
| Integration test suite | Extra Credit | 

## Configuration 

| Parameter | Required | Default | Description |
|---|---|---|---|
| auth_url | Yes | — | Full URL of the remote authentication server |
| header_name | Yes | Authorization | Name of the incoming request header to forward |
| header_value | No | — | If set, always send this value instead of the client's header |
| cache_ttl | No | 0 | Seconds to cache a successful (200) auth response. `0` disables caching |
| token_key | No | token | JSON key in the auth server response that holds the token |
| upstream_token_header | No | — | If set, extract the token and forward it to the upstream in this header |
| timeout | No | 5000 | HTTP timeout (ms) for the auth server call |

## How It Works
Client                   Kong (auth-plugin)              Auth Server          Upstream
  |--- GET /api --------->|                                   |                   |
  |                        |--- GET / (Authorization: X) ---->|                   |
  |                        |<-- 200 OK {"token":"jwt..."} ----|                   |
  |                        |--- GET /api (X-Auth-Token: jwt) ------------------>|
  |<-- 200 OK ------------|<---------------------------------------------------|
  
1. Client sends a request to Kong with a credential header (e.g. Authorization). 
2. The plugin reads the header (or uses the configured header_value). 
3. It calls the remote auth server, forwarding the credential. 
4. **200 OK** → request is proxied. Optionally, a token from the response body is injected into an upstream header. 
5. **Any other status** → the client receives the appropriate 40x error. 
When cache_ttl > 0, successful auth responses are cached in Kong's shared cache so repeated requests with the same credential skip the remote call.

## Installation
``` bash
luarocks install kong-plugin-auth-plugin
```

## Usage Example
``` bash
# Enable the plugin on a service
curl -X POST http://localhost:8001/services/my-service/plugins \
  --data "name=auth-plugin" \
  --data "config.auth_url=https://auth.example.com/auth" \
  --data "config.header_name=Authorization" \
  --data "config.cache_ttl=300" \
  --data "config.upstream_token_header=X-Auth-Token"
```
## Running Tests Tests use Pongo:
```bash
Pongo run
```

## Project Structure
kong-plugin-auth-plugin/
├── kong/plugins/auth-plugin/
│   ├── handler.lua          # Access-phase logic
│   └── schema.lua           # Plugin configuration schema
├── spec/auth-plugin/
│   └── 01-integration_spec.lua   # Integration tests
├── kong-plugin-auth-plugin-0.1.0-1.rockspec
└── README.md

## License