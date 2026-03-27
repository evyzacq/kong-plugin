
### Coding
#### plan
```text
1. Write schema.lua
   - Auth server URL 
   - Request header name
   - Configurable request header value 
   - Cache the response, for a configurable TTL 
   - Retrieve a key (assume a JWT) from the remote server response and include that in a (configurable) header so it is proxied with the request to the backend. 

2. Write the handler.lua skeleton — initially only "read header + call HTTP + check 200"

3. test manually with curl

4. Confirm the basic flow works

5. Add caching logic
   - Cache the response, for a configurable TTL 

6. Add JWT extraction logic
   - Retrieve a key (assume a JWT) from the remote server response and include that in a (configurable) header so it is proxied with the request to the backend. 

7. Write automated tests

8. Add production-grade features (timeout, fault tolerance, logging, security, Performance, deployment)

9. Write docs + rockspec
```

#### features for production
``` text
1. Caching for perf: Negative/key optimize
2. JWT:Support json dot-path
3. Error handing: fail-open/close
4. Security: oversize and leaking prevent
5. Debugging: debugging headers
6. Observability：metrics collection
7. scaling might be parted of kong.cache(to be confirmed)

```
20260327:
I initially planned to add more product-level features. 
However, with more I familiar with Kong’s plugin architecture, 
I realize it already provides robust mechanisms for handling different functional layers. 
To avoid logic overlap and potential performance degradation, I’ve decided to keep this plugin focused strictly on Authentication.

My focus is shifting to the following optimizations:
- header transformation: Ensuring flexibility across the client, Auth Server, and Upstream
- caching: md5-based keys are preferred and exploring Lua-specific caching techniques.
- connection: utilizing connection pooling to eliminate the overhead of repeated handshakes.
- scenario coverage: prioritizing header-based auth, direct forwarding scenario like machine accounts.



### Testing
#### Test Coverage
- Solid test coverage 

| #  | Scenario                 | Type        | What It Verifies                  |
| -- | ------------------------ | ----------- | --------------------------------- |
| 1  | Missing header → 401     | Integration | Basic rejection logic             |
| 2  | Invalid credential → 401 | Integration | Basic rejection logic             |
| 3  | Valid credential → 200   | Integration | Basic allow logic                 |
| 4  | Empty header value → 401 | Integration | Boundary condition                |
| 5  | `header_value` override  | Integration | Bonus feature                     |
| 6  | Inject JWT upstream      | Integration | Bonus feature                     |
| 7  | First cached request     | Integration | Cache write                       |
| 8  | Second cached request    | Integration | Cache read                        |
| 9  | Error message format     | Integration | Security (no internal leakage)    |
| 10 | Auth server timeout      | Integration | Fault tolerance                   |


#### Running Tests
##### Manual test
``` bash
dzhou2@DavidDesktop:~/github/kong-plugin$ ../kong-pongo/pongo.sh up
dzhou2@DavidDesktop:~/github/kong-plugin$ ../kong-pongo/pongo.sh shell

                /~\
  ______       C oo
  | ___ \      _( ^)
  | |_/ /__  _/__ ~\ __   ___
  |  __/ _ \| '_ \ / _ `|/ _ \
  | | | (_) | | | | (_| | (_) |
  \_|  \___/|_| |_|\__, |\___/
                    __/ |
                   |___/  v2.25.0

Kong version: 3.9.1


Error: /kong-plugin/kong-plugin-auth-plugin-0.1.0-1.rockspec: Mandatory field package is missing. (using rockspec format 1.0)
Kong auto-reload is enabled for custom-plugins and dbless-configurations. Once you
have started Kong, it will automatically reload to reflect any changes in the files.
Use 'pongo tail' on the host to verify, or do 'export KONG_RELOAD_CHECK_INTERVAL=0' in
this shell to disable it.

Get started quickly with the following aliases/shortcuts:
  kms   - kong migrations start; wipe/initialize the database and start Kong clean,
          optionally importing declarative configuration if available.
  kdbl  - kong start dbless; start Kong in dbless mode, requires a declarative configuration.
  ks    - kong start; starts Kong with the existing database contents (actually a restart).
  kp    - kong stop; stop Kong.
  kx    - export the current Kong database to a declarative configuration file.
  kauth - setup authentication (RBAC and GUI-auth).

[Kong-3.9.1:kong-plugin:/kong]$ ps -ef|grep -i kong|grep -v grep
[Kong-3.9.1:kong-plugin:/kong]$ kms
[Kong-3.9.1:kong-plugin:/kong]$ ps -ef|grep -i kong|grep -v grep
root         933       1  0 03:47 ?        00:00:00 nginx: master process /usr/local/bin/nginx -p /kong-plugin/servroot -c nginx.conf


[Kong-3.9.1:kong-plugin:/kong]$ curl -i -X POST http://localhost:8001/services \
  --data name=auth-service \
  --data url=http://httpbin.org/status/200
HTTP/1.1 201 Created
Date: Thu, 26 Mar 2026 04:48:36 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Content-Length: 382
X-Kong-Admin-Latency: 52
Server: kong/3.9.1

{"tags":null,"ca_certificates":null,"path":"/status/200","connect_timeout":60000,"read_timeout":60000,"host":"httpbin.org","write_timeout":60000,"tls_verify":null,"tls_verify_depth":null,"name":"auth-service","retries":5,"id":"84ca0c11-c60d-4c4a-800d-9b2d4a33c03c","protocol":"http","port":80,"created_at":1774500516,"updated_at":1774500516,"enabled":true,"client_certificate":null}[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$ curl -i -X POST http://localhost:8001/services/auth-service/routes \
  --data name=auth-route \
  --data paths[]=/validate
HTTP/1.1 201 Created
Date: Thu, 26 Mar 2026 04:48:55 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Content-Length: 486
X-Kong-Admin-Latency: 39
Server: kong/3.9.1

{"response_buffering":true,"paths":["/validate"],"headers":null,"hosts":null,"https_redirect_status_code":426,"service":{"id":"84ca0c11-c60d-4c4a-800d-9b2d4a33c03c"},"path_handling":"v0","regex_priority":0,"snis":null,"preserve_host":false,"id":"0777479b-a6c3-494d-bc9e-37452bdf3eba","sources":null,"tags":null,"protocols":["http","https"],"strip_path":true,"destinations":null,"name":"auth-route","created_at":1774500535,"updated_at":1774500535,"methods":null,"request_buffering":true}[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$ curl -i -X POST http://localhost:8001/services \
  --data name=business-service \
  --data url=http://httpbin.org/get
HTTP/1.1 201 Created
Date: Thu, 26 Mar 2026 04:49:02 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Content-Length: 379
X-Kong-Admin-Latency: 27
Server: kong/3.9.1

{"tags":null,"ca_certificates":null,"path":"/get","connect_timeout":60000,"read_timeout":60000,"host":"httpbin.org","write_timeout":60000,"tls_verify":null,"tls_verify_depth":null,"name":"business-service","retries":5,"id":"95c54c76-51c7-452d-8b1b-ea675c926f52","protocol":"http","port":80,"created_at":1774500542,"updated_at":1774500542,"enabled":true,"client_certificate":null}[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$ curl -i -X POST http://localhost:8001/services/business-service/routes \
  --data name=business-route \
  --data paths[]=/api
HTTP/1.1 201 Created
Date: Thu, 26 Mar 2026 04:49:23 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Content-Length: 485
X-Kong-Admin-Latency: 37
Server: kong/3.9.1

{"response_buffering":true,"paths":["/api"],"headers":null,"hosts":null,"https_redirect_status_code":426,"service":{"id":"95c54c76-51c7-452d-8b1b-ea675c926f52"},"path_handling":"v0","regex_priority":0,"snis":null,"preserve_host":false,"id":"c812730d-d8fd-4c30-a0af-8f4c762674a4","sources":null,"tags":null,"protocols":["http","https"],"strip_path":true,"destinations":null,"name":"business-route","created_at":1774500563,"updated_at":1774500563,"methods":null,"request_buffering":true}[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$ curl -i -X POST http://localhost:8001/routes/business-route/plugins \
  --data name=auth-plugin \
  --data config.auth_url=http://localhost:8000/validate \
  --data config.header_name=X-Custom-Token \
>
HTTP/1.1 201 Created
Date: Thu, 26 Mar 2026 04:51:40 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Content-Length: 475
X-Kong-Admin-Latency: 34
Server: kong/3.9.1

{"tags":null,"route":{"id":"c812730d-d8fd-4c30-a0af-8f4c762674a4"},"id":"ef42279b-4bbc-465b-8658-6adffc03c5f1","enabled":true,"consumer":null,"config":{"timeout":5000,"header_value":null,"upstream_token_header":null,"auth_url":"http://localhost:8000/validate","token_key":"token","cache_ttl":0,"header_name":"X-Custom-Token"},"service":null,"name":"auth-plugin","created_at":1774500700,"updated_at":1774500700,"instance_name":null,"protocols":["grpc","grpcs","http","https"]}[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$

```
1. Missing header → 401
``` bash
[Kong-3.9.1:kong-plugin:/kong]$ curl -i http://localhost:8000/api -H "X-Token: valid-secret"
HTTP/1.1 401 Unauthorized
Date: Thu, 26 Mar 2026 04:55:45 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Content-Length: 53
X-Kong-Response-Latency: 1
Server: kong/3.9.1
X-Kong-Request-Id: 5bc5e23d44194802d9b6927ae7b97b1d

{"message":"Missing required header: X-Custom-Token"}[Kong-3.9.1:kong-plugin:/kong]$
```

2. Invalid credential → 401
``` bash
[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$ curl -i -X PATCH http://localhost:8001/services/auth-service \
  --data url=http://httpbin.org/status/401
HTTP/1.1 200 OK
Date: Thu, 26 Mar 2026 04:59:24 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Content-Length: 382
X-Kong-Admin-Latency: 44
Server: kong/3.9.1

{"tags":null,"ca_certificates":null,"path":"/status/401","connect_timeout":60000,"read_timeout":60000,"host":"httpbin.org","write_timeout":60000,"tls_verify":null,"tls_verify_depth":null,"name":"auth-service","retries":5,"id":"84ca0c11-c60d-4c4a-800d-9b2d4a33c03c","protocol":"http","port":80,"created_at":1774500516,"updated_at":1774501164,"enabled":true,"client_certificate":null}[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$ curl -i http://localhost:8000/api -H "X-Custom-Token: valid-secret"
HTTP/1.1 401 Unauthorized
Date: Thu, 26 Mar 2026 04:59:33 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Content-Length: 35
X-Kong-Response-Latency: 1024
Server: kong/3.9.1
X-Kong-Request-Id: 7863991ab6361569c0ed4e26fe083226

{"message":"Authentication failed"}[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$ curl -i -X PATCH http://localhost:8001/services/auth-service \
  --data url=http://httpbin.org/status/200
HTTP/1.1 200 OK
Date: Thu, 26 Mar 2026 04:59:39 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Content-Length: 382
X-Kong-Admin-Latency: 12
Server: kong/3.9.1

{"tags":null,"ca_certificates":null,"path":"/status/200","connect_timeout":60000,"read_timeout":60000,"host":"httpbin.org","write_timeout":60000,"tls_verify":null,"tls_verify_depth":null,"name":"auth-service","retries":5,"id":"84ca0c11-c60d-4c4a-800d-9b2d4a33c03c","protocol":"http","port":80,"created_at":1774500516,"updated_at":1774501179,"enabled":true,"client_certificate":null}[Kong-3.9.1:kong-plugin:/kong]$
```

3. Valid credential → 200 
``` bash
[Kong-3.9.1:kong-plugin:/kong]$ curl -i http://localhost:8000/api -H "X-Custom-Token: valid-secret"
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 611
Connection: keep-alive
Date: Thu, 26 Mar 2026 04:56:03 GMT
Server: gunicorn/19.9.0
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Via: HTTP/1.1 s_proxy_lax, 1.1 kong/3.9.1
X-Kong-Upstream-Latency: 578
X-Kong-Proxy-Latency: 1532
X-Kong-Request-Id: 4316a11a9b76367a1ea8417d23f5237d

{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/8.5.0",
    "X-Amzn-Trace-Id": "Root=1-69c4bc63-6d884d665da71e654d3d3b9f",
    "X-Custom-Token": "valid-secret",
    "X-Forwarded-Host": "localhost",
    "X-Forwarded-Path": "/api",
    "X-Forwarded-Prefix": "/api",
    "X-Kong-Request-Id": "4316a11a9b76367a1ea8417d23f5237d",
    "X-Proxyuser-Ip": "117.135.15.123",
    "X-Sig-Request-Source": "0",
    "X-Sig-Xff-Exclusion": "0",
    "X-Tc-Profile-Ids": "[]"
  },
  "origin": "117.135.15.123, 155.190.3.5",
  "url": "http://localhost/get"
}
```

4. Empty header value → 401
``` bash
[Kong-3.9.1:kong-plugin:/kong]$ curl -i http://localhost:8000/api
HTTP/1.1 401 Unauthorized
Date: Thu, 26 Mar 2026 05:01:19 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Content-Length: 53
X-Kong-Response-Latency: 0
Server: kong/3.9.1
X-Kong-Request-Id: 5a4b7951b4afde1333e21b1e3de71b29

{"message":"Missing required header: X-Custom-Token"}[Kong-3.9.1:kong-plugin:/kong]$
```

5. `header_value` override
``` bash
[Kong-3.9.1:kong-plugin:/kong]$ curl -s http://localhost:8001/routes/business-route/plugins | jq
{
  "next": null,
  "data": [
    {
      "tags": null,
      "route": {
        "id": "c812730d-d8fd-4c30-a0af-8f4c762674a4"
      },
      "id": "ef42279b-4bbc-465b-8658-6adffc03c5f1",
      "enabled": true,
      "consumer": null,
      "config": {
        "timeout": 5000,
        "header_value": null,
        "upstream_token_header": null,
        "auth_url": "http://localhost:8000/validate",
        "token_key": "token",
        "cache_ttl": 0,
        "header_name": "X-Custom-Token"
      },
      "service": null,
      "name": "auth-plugin",
      "created_at": 1774500700,
      "updated_at": 1774500700,
      "instance_name": null,
      "protocols": [
        "grpc",
        "grpcs",
        "http",
        "https"
      ]
    }
  ]
}

[Kong-3.9.1:kong-plugin:/kong]$ curl -i -X PATCH http://localhost:8001/plugins/ef42279b-4bbc-465b-8658-6adffc03c5f1 \
  --data config.header_name=X-Token \
  --data config.header_value=MyConfiguredToken123 \
  --data config.token_key=X-JWT \
  --data config.upstream_token_header=X-Auth-Token2
HTTP/1.1 200 OK
Date: Thu, 26 Mar 2026 05:27:26 GMT
Content-Type: application/json; charset=utf-8
Connection: keep-alive
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Content-Length: 497
X-Kong-Admin-Latency: 103
Server: kong/3.9.1

{"tags":null,"route":{"id":"c812730d-d8fd-4c30-a0af-8f4c762674a4"},"id":"ef42279b-4bbc-465b-8658-6adffc03c5f1","enabled":true,"consumer":null,"config":{"timeout":5000,"header_value":"MyConfiguredToken123","upstream_token_header":"X-Auth-Token2","auth_url":"http://localhost:8000/validate","token_key":"X-JWT","cache_ttl":0,"header_name":"X-Token"},"service":null,"name":"auth-plugin","created_at":1774500700,"updated_at":1774502846,"instance_name":null,"protocols":["grpc","grpcs","http","https"]}[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$
[Kong-3.9.1:kong-plugin:/kong]$ curl -i http://localhost:8000/api -H "X-Token: client-valid-secret"
HTTP/1.1 200 OK
Content-Type: application/json
Content-Length: 611
Connection: keep-alive
Date: Thu, 26 Mar 2026 05:28:27 GMT
Server: gunicorn/19.9.0
Access-Control-Allow-Origin: *
Access-Control-Allow-Credentials: true
Via: HTTP/1.1 s_proxy_lax, 1.1 kong/3.9.1
X-Kong-Upstream-Latency: 594
X-Kong-Proxy-Latency: 1534
X-Kong-Request-Id: fa685b378ecc8b0f9579f0118fe5fa2e

{
  "args": {},
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin.org",
    "User-Agent": "curl/8.5.0",
    "X-Amzn-Trace-Id": "Root=1-69c4c3fb-4807f1c224f3393049f7cd8c",
    "X-Forwarded-Host": "localhost",
    "X-Forwarded-Path": "/api",
    "X-Forwarded-Prefix": "/api",
    "X-Kong-Request-Id": "fa685b378ecc8b0f9579f0118fe5fa2e",
    "X-Proxyuser-Ip": "117.135.15.123",
    "X-Sig-Request-Source": "0",
    "X-Sig-Xff-Exclusion": "0",
    "X-Tc-Profile-Ids": "[]",
    "X-Token": "client-valid-secret"
  },
  "origin": "117.135.15.123, 155.190.3.5",
  "url": "http://localhost/get"
}


```
##### Auto
`pongo run`
``` bash
dzhou2@DavidDesktop:~/github/kong-plugin$ ../kong-pongo/pongo.sh run
[pongo-INFO] auto-starting the test environment, use the 'pongo down' action to stop it
Container pongo-c367bf92-kong-run-3f89d07d0b1b Creating
Container pongo-c367bf92-kong-run-3f89d07d0b1b Created
Kong version: 3.9.1


kong-plugin-auth-plugin 0.1.0-1 depends on lua >= 5.1 (5.1-1 provided by VM: success)
Stopping after installing dependencies for kong-plugin-auth-plugin 0.1.0-1

●●●●●●●●●●
10 successes / 0 failures / 0 errors / 0 pending : 26.320914 seconds
dzhou2@DavidDesktop:~/github/kong-plugin$
```
or in shell
``` bash
[Kong-3.9.1:kong-plugin:/kong]$ busted /kong-plugin/spec/auth-plugin/10-integration_spec.lua
●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●
50 successes / 0 failures / 0 errors / 0 pending : 6.465606 seconds
[Kong-3.9.1:kong-plugin:/kong]$
```
20260327：
``` bash
[Kong-3.9.1:kong-plugin:/kong]$ busted /kong-plugin/spec/auth-plugin/10-integration_spec.lua
●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●●
50 successes / 0 failures / 0 errors / 0 pending : 6.404591 seconds
```
errors in log print are expected: 
``` bash
dzhou2@DavidDesktop:~/github/kong-plugin$ ../kong-pongo/pongo.sh tail|grep kong|grep err
tail: './servroot/logs/error.log' has become inaccessible: No such file or directory
tail: directory containing watched file was removed
tail: inotify cannot be used, reverting to polling
tail: './servroot/logs/error.log' has appeared;  following new file
tail: './servroot/logs/error.log' has been replaced;  following new file
2026/03/27 04:26:19 [error] 250101#0: *667 [kong] handler.lua:234 [auth-plugin] auth server unreachable: connection refused, client: 127.0.0.1, server: kong, request: "GET /echo HTTP/1.1", host: "dead.test", request_id: "786b19109b81451d8532192ac635420a"
2026/03/27 04:26:19 [error] 250101#0: *672 [kong] handler.lua:242 [auth-plugin] auth server returned 500, client: 127.0.0.1, server: kong, request: "GET /echo HTTP/1.1", host: "auth-500.test", request_id: "1ee51f3abb867d460fdb430a7cc76966"

```


### Debugging

#### 1. pongo run failed with lack of "rockspec" 20260326
``` bash
dzhou2@DavidDesktop:~/github/kong-plugin$ ../kong-pongo/pongo.sh run
[pongo-INFO] auto-starting the test environment, use the 'pongo down' action to stop it
Container pongo-c367bf92-kong-run-0ee1a8b98252 Creating
Container pongo-c367bf92-kong-run-0ee1a8b98252 Created
Kong version: 3.9.1


Error: /kong-plugin/kong-plugin-auth-plugin-0.1.0-1.rockspec: Mandatory field package is missing. (using rockspec format 1.0)

0 successes / 0 failures / 2 errors / 0 pending : 3.830508 seconds
```
create `kong-plugin-auth-plugin-0.1.0-1.rockspec` and `kong reload`

#### 2. httpmock server not working ！**issue**  20260326
2.1 http mock failed

``` lua
local fixtures = {
  http_mock = [[
    server {
      listen 0.0.0.0:]] .. MOCK_AUTH_PORT .. [[;
      server_name mock-auth;

      location = /auth {
        content_by_lua_block {
          local headers = ngx.req.get_headers()
          local auth_value_default = headers["X-Custom-Token"]
          local auth_value_config  = headers["X-Config-Token"]

          if auth_value_default == "valid-secret"
             or auth_value_config == "valid-config-secret" then
            ngx.status = 200
            ngx.header["Content-Type"] = "application/json"
            ngx.say('{"token":"token-123","X-JWT":"x-jwt-value"}')
            return
          end

          ngx.status = 401
          ngx.header["Content-Type"] = "application/json"
          ngx.say('{"message":"Authentication failed"}')
        }
      }
    }
  ]]
}
```
``` bash
Failure → /kong-plugin/spec/auth-plugin/10-integration_spec.lua @ 114
auth-plugin (integration) [#postgres] 2. Invalid credential -> 401
/kong-plugin/spec/auth-plugin/10-integration_spec.lua:118: Invalid response status code.
Status expected:
(number) 401
Status received:
(number) 502
Body:
(string) '{"message":"Auth server unreachable"}'
401

[Kong-3.9.1:kong-plugin:/kong]$ tail ../kong-plugin/servroot/logs/error.log
2026/03/26 07:04:08 [debug] 606#0: *648 [lua] http_connect.lua:253: execute_original_func(): poolname: http:127.0.0.1:26512:nil::nil:::
2026/03/26 07:04:08 [error] 606#0: *648 [kong] handler.lua:114 [auth-plugin] remote auth server unreachable: connection refused, client: 127.0.0.1, server: kong, request: "GET /api HTTP/1.1", host: "0.0.0.0:9000", request_id: "954db85c90febe0bfc183920cd481d56"
```
2.2 changed to business -> local auth -> httpbin, still cannot loop to 127.0.0.1 !
```lua
          host = helpers.mock_upstream_host,
          port = helpers.mock_upstream_port,
```

2.3 even built-in failed as well! 
``` bash
2026/03/26 10:35:37 [debug] 610#0: *646 [lua] http_connect.lua:253: execute_original_func(): poolname: http:127.0.0.1:15555:nil::nil:::
2026/03/26 10:35:37 [error] 610#0: *646 [kong] handler.lua:114 [auth-plugin] remote auth server unreachable: connection refused, client: 127.0.0.1, server: kong, request: "GET /api HTTP/1.1", host: "test-ok.example.com", request_id: "618915346fd55c235cf64816b67cb149"
```

2.4 worked after rewrite, but the main idles were same
NOTE: `kauth` and `pongo expose` 
** pending diving**

#### 3. cache test case failed  20260327
``` bash
[Kong-3.9.1:kong-plugin:/kong]$ busted /kong-plugin/spec/auth-plugin/10-integration_spec.lua
●●●●●●●●●●●●◼●●●●●●●●●●◼●●●●●●●●●●●●●◼●●●●●●●●●●◼●
46 successes / 4 failures / 0 errors / 0 pending : 8.719265 seconds

Failure → /kong-plugin/spec/auth-plugin/10-integration_spec.lua @ 572
auth-plugin integration [#postgres] cache_ttl: repeated requests succeed (cache does not break flow)
/kong-plugin/spec/auth-plugin/10-integration_spec.lua:605: Invalid response status code.
Status expected:
(number) 403
Status received:
(number) 502
Body:
(string) '{"message":"Auth service unavailable"}'
403

Failure → /kong-plugin/spec/auth-plugin/10-integration_spec.lua @ 786
auth-plugin integration [#postgres] cache isolation: GET and POST routes don't share cache
/kong-plugin/spec/auth-plugin/10-integration_spec.lua:811: Invalid response status code.
Status expected:
(number) 403
Status received:
(number) 502
Body:
(string) '{"message":"Auth service unavailable"}'
403
```

log was added for debugging, cache_err check was removed  as well:
``` lua
    local cached, cache_err = kong.cache:get(key, { ttl = conf.cache_ttl }, function()
      local b, h, s, call_err = authenticate(conf, credential)
      kong.log.err("TempLog: ", call_err, b, h, s)
```
got this
``` bash
2026/03/27 03:06:30 [error] 236429#0: *671 [kong] handler.lua:203 [auth-plugin] TempLog: nil{"message":"Method-sensitive POST forbidden"}
2026/03/27 03:06:30 [error] 236429#0: *671 [kong] init.lua:406 [auth-plugin] /kong-plugin/kong/plugins/auth-plugin/handler.lua:235: attempt to compare nil with number, client: 127.0.0.1, server: kong, request: "POST /echo HTTP/1.1", host: "cache-post.test", request_id: "e1542957b238583fec0f3e401982a30e"
```
non-200 responses are dropped, resulting in false 502 errors. 
code change:
``` lua
    local key = cache_key(conf, credential)
    local cached, cache_err = kong.cache:get(key, { ttl = conf.cache_ttl }, function()
      local b, h, s, call_err = authenticate(conf, credential)
      kong.log.err("dzhou: ", call_err, b, h, s)
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
```
