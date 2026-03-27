# kong-plugin-auth-plugin

A Kong Gateway plugin that delegates credential validation to a remote HTTP
authentication server. The plugin extracts a credential from the incoming
request (header, query parameter, or cookie), forwards it to the auth server,
and either proxies the request or rejects it based on the response status code.

**Version:** 0.2.0

## Features

| Feature | Description |
|---|---|
| Multi-source credential extraction | Read credentials from headers, query parameters, or cookies |
| Configurable auth method | `GET`, `POST`, `PUT`, or `HEAD` to the auth server |
| Configurable success codes | Any set of 2xx codes can mean "auth succeeded" |
| Trusted credentials fast-path | Skip the auth server entirely for known machine tokens |
| Token forwarding | Extract a value from the auth response JSON (dot-path supported) and inject it upstream |
| Upstream header forwarding | Forward specific auth response headers to the upstream, with a configurable blocklist |
| Response caching | Cache successful auth results with configurable TTL |
| Connection pooling | Persistent connections to the auth server with configurable keepalive |
| Split timeouts | Separate connect, send, and read timeouts |
| Credential override | Optionally send a static credential instead of the client's value |

## Configuration

| Parameter | Required | Default | Description |
|---|---|---|---|
| `auth_url` | **Yes** | -- | Full URL of the remote authentication server |
| `auth_method` | No | `GET` | HTTP method for the auth request (`GET`, `POST`, `PUT`, `HEAD`) |
| `credential_source` | No | `header` | Where to read the credential: `header`, `query`, or `cookie` |
| `credential_name` | No | `Authorization` | Name of the header / query param / cookie to read. If it contains dots (e.g. cookies), `header_name` must be set explicitly |
| `header_name` | No | -- | Header name used when forwarding credential to auth server (defaults to `credential_name`). Required if `credential_name` contains dots |
| `header_value` | No | -- | If set, send this static value instead of the client's credential (encrypted at rest) |
| `success_codes` | No | `[200]` | Set of HTTP status codes (2xx) that indicate auth success |
| `trusted_credentials` | No | -- | Credentials that bypass the auth server entirely (encrypted at rest) |
| `connect_timeout` | No | `2000` | TCP connect timeout in ms (1--30000) |
| `read_timeout` | No | `5000` | Read timeout in ms (1--60000) |
| `send_timeout` | No | `5000` | Send timeout in ms (1--60000) |
| `keepalive_timeout` | No | `60000` | Keepalive timeout in ms for connection pooling (0--300000) |
| `keepalive_pool_size` | No | `60` | Max idle connections per worker (1--1000) |
| `cache_ttl` | No | `0` | Seconds to cache successful auth responses. `0` disables caching (0--86400) |
| `max_body_size` | No | `65536` | Max bytes to retain from auth response body; full body is read then truncated (256--1048576) |
| `token_key` | No | `token` | JSON key (dot-path supported, e.g. `data.access_token`) in auth response holding the token |
| `upstream_token_header` | No | -- | If set, extracted token is forwarded upstream in this header |
| `upstream_headers` | No | -- | Set of auth response header names to forward to the upstream |
| `blocked_headers` | No | *(hop-by-hop defaults)* | Headers blocked from forwarding (lowercase only, overridable) |

## How It Works

```
Client                   Kong (auth-plugin)              Auth Server          Upstream
  |--- GET /api --------->|                                   |                   |
  |                        |--- GET / (Authorization: X) ---->|                   |
  |                        |<-- 200 OK {"token":"jwt..."} ----|                   |
  |                        |--- GET /api (X-Auth-Token: jwt) ------------------>|
  |<-- 200 OK ------------|<---------------------------------------------------|
```

1. Client sends a request with a credential (header, query param, or cookie).
2. The plugin extracts the credential (or uses `header_value` if configured).
3. If the credential is in `trusted_credentials`, the request is proxied immediately.
4. Otherwise, the plugin calls the auth server, forwarding the credential.
5. If the response status is in `success_codes` -> request is proxied.
   Optionally, a token from the response body and/or specific response headers
   are injected into the upstream request.
6. Auth server 4xx -> the client receives the same 4xx status.
7. Auth server 5xx or unreachable -> the client receives 502.

When `cache_ttl > 0`, successful auth responses are cached in Kong's shared
cache so repeated requests with the same credential skip the remote call.
Failed auth responses are not cached.

## Installation

```bash
luarocks install kong-plugin-auth-plugin
```

Or place the plugin files on your Lua path and add `auth-plugin` to the
`plugins` configuration directive:

```
plugins = bundled,auth-plugin
```

## Usage Examples

### Basic header-based auth

```bash
curl -X POST http://localhost:8001/services/my-service/plugins \
  --data "name=auth-plugin" \
  --data "config.auth_url=https://auth.example.com/validate" \
  --data "config.cache_ttl=300" \
  --data "config.upstream_token_header=X-Auth-Token"
```

### Query parameter credential with POST method

```bash
curl -X POST http://localhost:8001/services/my-service/plugins \
  --data "name=auth-plugin" \
  --data "config.auth_url=https://auth.example.com/check" \
  --data "config.auth_method=POST" \
  --data "config.credential_source=query" \
  --data "config.credential_name=api_key"
```

### Cookie credential with trusted fast-path

```bash
curl -X POST http://localhost:8001/services/my-service/plugins \
  --data "name=auth-plugin" \
  --data "config.auth_url=https://auth.example.com/session" \
  --data "config.credential_source=cookie" \
  --data "config.credential_name=session_id" \
  --data "config.trusted_credentials=health-check-token" \
  --data "config.trusted_credentials=machine-service-token"
```

### Dot-path token extraction + header forwarding

```bash
curl -X POST http://localhost:8001/services/my-service/plugins \
  --data "name=auth-plugin" \
  --data "config.auth_url=https://auth.example.com/validate" \
  --data "config.token_key=data.access_token" \
  --data "config.upstream_token_header=X-Auth-Token" \
  --data "config.upstream_headers=X-User-ID" \
  --data "config.upstream_headers=X-Tenant"
```

## Running Tests

Tests use Kong's Pongo test framework:

```bash
# From the plugin root directory
pongo run -- spec/auth-plugin/

# Run specific test files
pongo run -- spec/auth-plugin/01-integration_spec.lua
```

## Project Structure

```
kong-plugin-auth-plugin/
├── kong/plugins/auth-plugin/
│   ├── handler.lua                         # Access-phase logic (v0.2.0)
│   └── schema.lua                          # Plugin configuration schema
├── spec/auth-plugin/
│   ├── 01-integration_spec.lua             # Integration tests (http_mock)
├── kong-plugin-auth-plugin-0.2.0-1.rockspec
└── README.md
```

## License

MIT