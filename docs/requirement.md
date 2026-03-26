# Task: 

Create a Kong authentication plugin. Upon receiving a request in Kong the plugin will reach out to a remote server, with a header from the incoming request. If the remote server returns a “200 OK”, the request is allowed to be proxied, on anything else the client should get the proper “40x” response. 

### The plugin must admit at least these 2 configuration options on its schema: 
- Auth server URL 
- Request header name There should be at least 1 integration test. 

You will be evaluated on how you deal with problems (flexibility, creativity) and on how your code looks, not on how well the final plugin works. 

### Extra Credits: 

- Configurable request header value 
- Solid test coverage 
- Cache the response, for a configurable TTL 
- Retrieve a key (assume a JWT) from the remote server response and include that in a (configurable) header so it is proxied with the request to the backend. 

### Docs/Help: 
- Quick introduction to Routes, Services and Plugins: https://docs.konghq.com/gateway/latest/get-started/quickstart/ 
- Plugin development (slightly outdated): https://docs.konghq.com/latest/plugin-development
- PDK (plugin development kit): https://docs.konghq.com/gateway/latest/pdk/ (note the nav bars on the left as well as on the right of this page)
- Local test environment: https://github.com/kong/kong-pongo
- Plugin template: https://github.com/Kong/kong-plugin 

When setting up the development environment it may be helpful to use some external services like http://mockbin.org or http://httpbin.org to provide a test backend for your plugin (or the one that comes with the Kong test setup, see existing tests for examples). 
There are a number of publicly available plugins (in their own Github repos, or in the Kong repo) that can also serve as examples for you to follow for this exercise.