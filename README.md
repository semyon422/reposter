# reposter
Posts new videos from youtube to vk  

## lua deps added as files
ljsqlite3: https://github.com/stepelu/lua-ljsqlite3 https://www.sqlite.org/index.html  
log.lua: https://github.com/rxi/log.lua

http_util, table_util, Orm, xsys(string): https://github.com/semyon422/aqua
bash scripts: https://github.com/semyon422/lua-dev-env

## lua deps installed using luarocks
luasec (openssl): https://github.com/brunoos/luasec https://curl.haxx.se/libcurl/c/  
lua-cjson: https://github.com/openresty/lua-cjson  
date: https://github.com/Tieske/date  

## vk.com access token

```
scope = 16 + 8192 + 65536 -- video + wall + offline = 73744

https://oauth.vk.com/authorize?client_id=6460245&display=page&scope=73744&response_type=token&v=5.103&redirect_uri=https://oauth.vk.com/blank.html

redirects to

https://oauth.vk.com/blank.html#access_token=ACCESS_TOKEN&expires_in=0&user_id=USER_ID
```