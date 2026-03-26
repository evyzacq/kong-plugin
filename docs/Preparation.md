# A Learning Guide

> Goal: After reading this guide, you should be able to build a Kong plugin

---

## 1. Prerequisite Knowledge

### 1.1 Lua Quick Reference

- install: sudo apt install lua5.x
- [lua](https://www.lua.org/start.html)

```lua
-- types:
--- nil/boolean/number/string/table/function

-- nail & boolean
--- nil and false are falsy; 
--- everything else is truthy (including 0 and "") !!

-- Variables
x = 10                       -- global
local x = 10                 -- local scope (always use local; globals are a big Lua anti-pattern)
local s = "hello"
local t = { a = 1, b = 2 }   -- table = Lua’s universal data structure (array + dictionary), the first index is 1 !!
                             -- t["a"], t.a, t[1]

-- Functions
local function add(a, b)
  return a + b
end

-- Multiple return values (idiomatic Lua pattern: value, err)
local result, err = some_function()
if not result then
  print("error: " .. err)
end

-- String operations
string.format("hello %s, age %d", "world", 25)
s:gmatch("[^%.]+")  -- iterator, split by .

-- Conditionals
if x > 0 then 
    ...
elseif x == 0 then 
    ... 
else 
    ...
end

-- while
local i = 1
while i <= 3 do
  print(i)
  i = i + 1
end

-- for
local arr = {"Lua", "Python", "Go"}

for i, v in ipairs(arr) do
  print(i, v)
end

-- Modules
local m = require("math_utils")
print(m.add(1, 2))
print(m.sub(5, 3))

-- OO
local Person = {}
function Person:new(name, age)
    ...
end

local p = Person:new("Alice", 25)

-- run
lua main.lua
```

### 1.2 Convention
### 1.3 Best Practice

---

## 2. Core Kong Concepts

### 2.1 The Three Core Objects

```text
                    ┌──────────┐
  Client ──────→    │  Route   │  Matching rules: host / path / method
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │  Service │  Upstream backend address: http://backend:8080 ---> httpbin
                    └────┬─────┘
                         │
                    ┌────▼─────┐
                    │  Plugin  │  Middleware logic: auth, rate limiting, logging...
                    └──────────┘
```

* **Service**: Where your backend API lives
* **Route**: Which requests should be forwarded to that Service (matched by host, path, method)
* **Plugin**: Extra processing logic attached to a Route or Service

### 2.2 Request Lifecycle

```text
Client Request
    │
    ▼
┌─────────┐  Internal Nginx phases inside Kong:
│ rewrite │  URL rewriting (rarely used)
├─────────┤
│ access  │  ← authentication / authorization / rate limiting  <----Our plugin
├─────────┤
│ balancer│  Select upstream node via load balancing
├─────────┤
│ header_ │  Modify response headers
│ filter  │
├─────────┤
│ body_   │  Modify response body
│ filter  │
├─────────┤
│ log     │  Record logs / metrics
└─────────┘
    │
    ▼
Client Response
```

### 2.3 PDK

These are the APIs Kong provides for manipulating requests and responses inside a plugin:

```lua
-- Read the request
kong.request.get_header("Authorization")   -- get a request header
kong.request.get_method()                  -- GET/POST/...
kong.request.get_path()                    -- /api/v1/users

-- Modify the request sent upstream
kong.service.request.set_header("X-Token", "abc")  -- add a header to the upstream request

-- Return a response directly to the client (stop proxying)
kong.response.exit(401, { message = "Unauthorized" })

-- Modify the response returned to the client
kong.response.set_header("X-Debug", "true")

-- Cache
kong.cache:get(key, opts, callback_fn)

-- Logging
kong.log.debug("detail info")   -- for development
kong.log.info("normal info")    -- normal information
kong.log.warn("warning")        -- something to pay attention to
kong.log.err("error")           -- something went wrong
```

### 2.4 Plugin Loading Mechanism

```text
Configured in kong.conf:
  plugins = bundled,remote-auth

When Kong starts:
  1. Scan kong/plugins/<name>/ under lua_package_path
  2. Load schema.lua → register configuration schema
  3. Load handler.lua → register phase handlers
  4. When a plugin instance is configured through the Admin API, validate config with schema
  5. When a request arrives, execute plugin handlers in PRIORITY order
```

---

## 3. Plugin Development Workflow

### 3.1 File Structure
- [Kong official Plugins](https://github.com/Kong/kong/blob/master/kong/plugins/)
- [Plugin template](https://github.com/Kong/kong-plugin)

```text
kong-auth-plugin/
├── kong/plugins/remote-auth/
│   ├── schema.lua      ← write this first: defines "what config the plugin accepts"
│   └── handler.lua     ← write this second: defines "what the plugin does in each phase"
├── spec/               ← third step: write tests
├── *.rockspec          ← package definition file
└── README.md
```


### 3.2 Running Tests
- [Local test environment](https://github.com/kong/kong-pongo)
- Install
``` bash
git clone https://github.com/Kong/kong-plugin.git
cd kong-plugin
```
- Debugging/Manual 
``` bash
# start containers 
pongo.sh up

# get in container
pongo.sh shell
## kong cmd in shell
kong migrations bootstrap
kong prepare && kong start
```

- Auto test
``` bash
# auto pull and build the test images
pongo run
```

- Manual test
** Route match --> Plugin --> Service --> BackendAPI **
```bash
# setup 8001
## create Service
curl -i -X POST http://localhost:8001/services \
  --data name=test-svc \
  --data url=http://httpbin.org/get

## create Route
curl -i -X POST http://localhost:8001/services/test-svc/routes \
  --data name=test-route \
  --data 'paths[]=/hello'

## load plugin
curl -i -X POST http://localhost:8001/routes/test-route/plugins \
  --data name=my-token-plugin

# test
curl -i http://localhost:8000/hello
```