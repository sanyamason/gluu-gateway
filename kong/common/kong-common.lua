local constants = require "kong.constants"
local utils = require "kong.tools.utils"
local oxd = require "gluu.oxdweb"
local jwt = require "resty.jwt"
local evp = require "resty.evp"
local validators = require "resty.jwt-validators"
local cjson = require"cjson"
local pl_tablex = require "pl.tablex"
local path_wildcard_tree = require "gluu.path-wildcard-tree"
local json_cache = require "gluu.json-cache"

-- EXPIRE_DELTA_SECONDS should be not big positive number, IMO in range from 2 to 10 seconds
local EXPIRE_DELTA_SECONDS = 5

local MAX_PENDING_SLEEP_MS = 200 -- 200 * 5ms = 1 seconds max waiting for pending operation
local PENDING_SLEEP_SEC = 0.005
local PENDING_EXPIRE = 0.2
local PENDING_TABLE = {}

local lrucache = require "resty.lrucache.pureffi"
-- it is shared by all the requests served by each nginx worker process:
local worker_cache, err = lrucache.new(10000) -- allow up to 10000 items in the cache
if not worker_cache then
    return error("failed to create the cache: " .. (err or "unknown"))
end

local function unexpected_error(...)
    local pending_key = kong.ctx.plugin.pending_key
    if pending_key then
        worker_cache:delete(pending_key)
    end
    kong.log.err(...)
    kong.response.exit(502, { message = "An unexpected error ocurred" })
end

local function load_consumer_by_id(consumer_id)
    local result, err = kong.db.consumers:select({ id = consumer_id })
    if not result then
        if not err then
            err = 'consumer "' .. consumer_id .. '" not found'
        end

        return nil, err
    end
    kong.log.debug("consumer loaded")
    return result
end

local function get_token(authorization)
    if authorization and #authorization > 0 then
        local from, to, err = ngx.re.find(authorization, "\\s*[Bb]earer\\s+(.+)", "jo", nil, 1)
        if from then
            return authorization:sub(from, to) -- Return token
        end
        if err then
            return unexpected_error(err)
        end
    end

    return nil
end

-- here we store access tokens per client_id
local access_tokens_per_client_id = {}

local function get_protection_token(conf)
    local access_token_data = access_tokens_per_client_id[conf.client_id]
    if not access_token_data then
        local response, err = oxd.get_client_token(conf.oxd_url,
            {
                client_id = conf.client_id,
                client_secret = conf.client_secret,
                scope = { "openid", "oxd" },
                op_host = conf.op_url,
            })

        local body = response.body
        if response.status >= 300 or not body.access_token then
            access_tokens_per_client_id[conf.client_id] = nil
            return unexpected_error("Failed to get access token")
        end

        access_token_data = body
        access_token_data.expire = ngx.time() + body.expires_in
        access_tokens_per_client_id[conf.client_id] = access_token_data
        return access_token_data.access_token
    end

    local now = ngx.time()
    local ptoken = access_token_data.token

    kong.log.debug("Current datetime: ", now, " access_token_data.expire: ", access_token_data.expire)
    if access_token_data.expire > now - EXPIRE_DELTA_SECONDS then
        return access_token_data.access_token
    end

    if access_token_data.refresh_pending then
        for i = 1, MAX_PENDING_SLEEP_MS do
            kong.log.debug("sleep")
            ngx.sleep(PENDING_SLEEP_SEC)
            if not access_token_data.refresh_pending then
                if access_token_data.expire > now - EXPIRE_DELTA_SECONDS then
                    return access_token_data.access_token
                end
                return unexpected_error("Failed to get access token, pending operation failed")
            end
        end
        return unexpected_error("Failed to get access token, pending operation  timeout")
    end

    -- token will expire soon, we are trying to refresh it
    -- avoid multiple token requests
    access_token_data.refresh_pending = true

    local refresh_token = access_token_data.refresh_token

    local response, err
    if refresh_token then
        local response, err = oxd.get_access_token_by_refresh_token(conf.oxd_url,
            {
                oxd_id = conf.oxd_id,
                refresh_token = refresh_token,
            },
            ptoken)

        local body = response.body
        if response.status < 300 and body.access_token then
            access_token_data = body
            access_token_data.expire = ngx.time() + response.body.expires_in
            access_tokens_per_client_id[conf.client_id] = access_token_data
            access_token_data.refresh_pending = nil
            return access_token_data.access_token
        end
    end

    -- last chance, get_access_token by client credentials
    local response, err = oxd.get_client_token(conf.oxd_url,
        {
            client_id = conf.client_id,
            client_secret = conf.client_secret,
            scope = { "openid", "oxd" },
            op_host = conf.op_url,
        })

    access_token_data.refresh_pending = nil
    local body = response.body
    if response.status >= 300 or not body.access_token then
        access_tokens_per_client_id[conf.client_id] = nil
        return unexpected_error("Failed to get access token, status: ", response.status)
    end

    access_token_data = body
    access_token_data.expire = ngx.time() + body.expires_in
    access_tokens_per_client_id[conf.client_id] = access_token_data
    return access_token_data.access_token
end

-- here we store jwks per op_url
local jwks_per_op = {}

local supported_algs = {
    RS256 = true,
    RS384 = true,
    RS512 = true,
}

local function refresh_jwks(self, conf, jwks)
    local ptoken = get_protection_token(conf)

    local response, err = oxd.get_jwks(conf.oxd_url,
        { op_host = conf.op_url },
        ptoken)
    if not response then
        kong.log.err(err)
        return
    end
    if response.status ~= 200 then
        kong.log.err("get_jwks responds with status: ", response.status)
        return
    end

    kong.log.inspect(response)
    local keys = response.body.keys
    if not keys then
        kong.log.err("get_jwks missed keys")
        return
    end

    jwks:flush_all()

    for i = 1, #keys do
        local key = keys[i]
        local ttl = key.exp - ngx.now()
        local alg = key.alg
        if ttl > 0 and supported_algs[alg] and
                key.x5c and type(key.x5c) == "table" and key.x5c[1] then
            local pem = "-----BEGIN CERTIFICATE-----\n" ..
                    key.x5c[1] ..
                    "\n-----END CERTIFICATE-----\n"
            local pkey, err = jwt.pem_cert_to_public_key(pem)
            if pkey then
                key.pkey = pkey
                jwks:set(key.kid, key, ttl)
            else
                kong.log.err("Cannot convert x5c into public key: ", err)
            end
        end
    end
    return true
end

local function process_jwt(self, conf, jwt_obj)
    if not supported_algs[jwt_obj.header.alg] then
        kong.log.info("JWT - unsupported alg=", jwt_obj.header.alg)
        return nil, 401, "Bad JWT"
    end
    local kid = jwt_obj.header.kid
    if kid == nil then
        kong.log.info("JWT - missed kid")
        return nil, 401, "JWT - missed kid"
    end

    local jwks = jwks_per_op[conf.op_url]
    if jwks then
        local key = jwks:get(kid)
        if not key then
            if not refresh_jwks(self, conf, jwks) then
                return nil, 502, "Unexpected error"
            end
        end
    else
        local cache, err = lrucache.new(20) -- allow up to 20 items in the cache
        if not cache then
            return nil, 502, "failed to create the jwks cache: " .. (err or "unknown")
        end
        jwks_per_op[conf.op_url] = cache
        jwks = cache
        if not refresh_jwks(self, conf, jwks) then
            return nil, 502, "Unexpected error"
        end
    end
    local key = jwks:get(kid)
    if not key then
        kong.log.info("Unknown kid")
        return nil, 401, "Unknown kid"
    end


    local claim_spec = {
        exp = validators.is_not_expired(),
    }

    if jwt_obj.header.alg ~= key.alg then
        kong.log.info("JWT - alg mismatch")
        return nil, 401, "Bad JWT"
    end

    kong.log.debug("verify with cert: \n", key.pem)
    local verified = jwt:verify_jwt_obj_evp_pkey(key.pkey, jwt_obj, claim_spec)

    if not verified.verified then
        kong.log.info("JWT is not verified, reason: ", jwt_obj.reason)
        return nil, 401, "JWT is not verified, reason: ", jwt_obj.reason
    end

    local payload = jwt_obj.payload
    kong.log.inspect(payload)
    if payload.client_id and payload.exp then
        return payload, 200
    end

    kong.log.info("JWT - malformed payload")
    return nil, 401, "JWT - malformed payload"
end

local function get_phantom_token(token_data)
    local header = ngx.encode_base64(cjson.encode({ typ = "JWT", alg = "none" }))
    local payload = ngx.encode_base64(cjson.encode(token_data))
    local phantom_token = table.concat({
        header,
        ".",
        payload,
        "."
    })

    return phantom_token
end

local function request_authenticated(conf, token_data)
    kong.log.debug("request_authenticated")
    if conf.pass_credentials == "hide" then
        kong.log.debug("Hide authorization header")
        kong.service.request.clear_header("authorization")
    end

    if conf.pass_credentials == "phantom_token" and token_data.active then
        kong.log.debug("Phantom token requested")
        kong.service.request.set_header("authorization", "Bearer " .. get_phantom_token(token_data))
    end

    local consumer = token_data.consumer
    local const = constants.HEADERS
    local new_headers = {
        [const.CONSUMER_ID] = consumer.id,
        [const.CONSUMER_CUSTOM_ID] = tostring(consumer.custom_id),
        [const.CONSUMER_USERNAME] = tostring(consumer.username),
    }

    local client_id = token_data.client_id
    if client_id then
        new_headers["X-OAuth-Client-ID"] = tostring(client_id)

        -- introspect-rpt API return mandatory `permissions` field
        if token_data.permissions then
            new_headers["X-RPT-Expiration"] = tostring(token_data.exp)
        else
            new_headers["X-OAuth-Expiration"] = tostring(token_data.exp)

            local scope = token_data.scope
            local t = {}
            for i = 1, #scope do
                t[#t + 1] = scope[i]
            end
            new_headers["X-Authenticated-Scope"] = table.concat(t, ", ")
        end

        kong.service.request.clear_header(const.ANONYMOUS) -- in case of auth plugins concatenation
    else
        new_headers[const.ANONYMOUS] = true
    end
    kong.service.request.set_headers(new_headers)
end

-- lru cache get operation with `pending` state support
local function worker_cache_get_pending(key)
    for i = 1, MAX_PENDING_SLEEP_MS do
        local token_data, stale_data = worker_cache:get(key)

        if not token_data or stale_data then
            return
        end

        if token_data == PENDING_TABLE then
            kong.log.debug("sleep")
            ngx.sleep(PENDING_SLEEP_SEC)
        else
            return token_data
        end
    end
end

local function set_pending_state(key)
    kong.ctx.plugin.pending_key = key
    worker_cache:set(key, PENDING_TABLE, PENDING_EXPIRE)
end

local function clear_pending_state(key)
    kong.ctx.plugin.pending_key = nil
    worker_cache:delete(key)
end

local function handle_anonymous(conf, scope_expression, status, err)
    kong.log.debug("conf.anonymous: ", conf.anonymous)
    local consumer_cache_key = kong.db.consumers:cache_key(conf.anonymous)
    local consumer, err = kong.cache:get(consumer_cache_key, nil, load_consumer_by_id, conf.anonymous)

    if err then
        return unexpected_error("Anonymous customer: ", err)
    end
    request_authenticated(conf, { consumer = consumer })
end

local _M = {}

_M.unexpected_error = unexpected_error

_M.get_path_with_base_url = function(path)
    local server_port = ngx.var.server_port
    local scheme = ngx.var.scheme
    local port = ((server_port == "80" and scheme == "http") or (server_port == "443" and scheme == "https"))
            and "" or ":" .. server_port

    local url_params = {
        scheme,
        "://",
        ngx.var.host,
        port,
        path,
    }

    return table.concat(url_params)
end

--- Fetch oauth scope expression based on path and http methods
-- Details: https://github.com/GluuFederation/gluu-gateway/issues/179#issuecomment-403453890
-- @param self: Kong plugin object
-- @param exp: OAuth scope expression Example: [{ path: "/posts", ...}, { path: "/todos", ...}] it must be sorted - longest strings first
-- @param request_path: requested api endpoint(path) Example: "/posts/one/two"
-- @param method: requested http method Example: GET
-- @return json protected_path path, expression Example: {path: "/posts", ...}
local function get_path_by_request_path_method(self, conf, path, method)
    local method_path_tree = json_cache(conf.method_path_tree)

    local rule = path_wildcard_tree.matchPath(method_path_tree, method, path)

    if rule then
        return rule.path, rule.scope_expression
    end
end


--[[
hooks must be a table with methods below:

it shoud never return, it must call kong.exit
function hooks.no_token_protected_path(self, conf, protected_path, method)
end

@return nil or cache key
also may return second value `pending` which means the plugin will call async. operations
function build_cache_key(method, protected_path, token, scopes)

@return boolean
function hooks.is_access_granted(self, conf, protected_path, method, scope_expression, scopes, rpt)
end
 ]]
_M.access_pep_handler = function(self, conf, hooks)
    local token = kong.ctx.shared.request_token

    local method = ngx.req.get_method()
    local path = ngx.var.uri:match"^([^%s]+)"
    local protected_path, scope_expression = get_path_by_request_path_method(self, conf, path, method)

    if token and not protected_path and conf.deny_by_default then
        kong.log.err("Path: ", path, " and method: ", method, " are not protected with scope expression. Configure your scope expression.")
        return kong.response.exit(403, { message = "Unprotected path/method are not allowed" })
    end

    if not token then
        if protected_path then
            kong.log.debug("no token, protected path")
            return hooks.no_token_protected_path(self, conf, protected_path, method)
        end

        if conf.deny_by_default == false then
            kong.log.debug("no token, no protected path but conf.deny_by_default = false so access allow")
            return
        end
        return kong.response.exit(403, { message = "Invalid request, no token and no protected path" })
    end

    kong.log.debug("protected resource path: ", protected_path, " URI: ", path, " token: ", token)

    local client_id, exp
    local token_data = kong.ctx.shared.request_token_data
    if not token_data then
        return kong.response.exit(403, { message = "Token not authenticated" })
    else
        exp = token_data.exp
    end

    if not protected_path then
        return -- access_granted
    end

    local cache_key, pending = hooks.build_cache_key(method, protected_path, token, token_data.scope)

    if cache_key then
        local is_access_granted = worker_cache_get_pending(cache_key)
        if is_access_granted then
            kong.ctx.shared[self.metric_client_granted] = true
            return -- access_granted
        end
    end

    if pending then
        set_pending_state(cache_key)
    end
    if hooks.is_access_granted(self, conf, protected_path, method, scope_expression, token_data.scope, token) then
        if cache_key then
            worker_cache:set(cache_key, true, exp - ngx.now() - EXPIRE_DELTA_SECONDS)
        end
        kong.ctx.shared[self.metric_client_granted] = true
        return -- access_granted
    end
    if pending then
        clear_pending_state(token)
    end
    return kong.response.exit(403, { message = "You are not authorized to access this resource" })
end

--[[
Authentication

introspect_token hooks must be a table with methods below:

@return introspect_response, status, err
upon success returns only introspect_response,
otherwise return nil, status, err
function introspect_token(self, conf, token)
end
 ]]
_M.access_auth_handler = function(self, conf, introspect_token)
    local authorization = ngx.var.http_authorization
    local token = get_token(authorization)

    if not token then
        if #conf.anonymous > 1 then --TODO
            return handle_anonymous(conf)
        end
        return kong.response.exit(401, { message = "Failed to get bearer token from Authorization header" })
    end

    local client_id, exp
    local token_data = worker_cache_get_pending(token)
    if not token_data then
        set_pending_state(token)

        local introspect_response, status, err

        local jwt_obj = jwt:load_jwt(token)
        if jwt_obj.valid then
            introspect_response, status, err = process_jwt(self, conf, jwt_obj)
        else
            introspect_response, status, err = introspect_token(self, conf, token)
        end
        token_data = introspect_response

        if not introspect_response then
            clear_pending_state(token)

            if status ~= 401 then
                return unexpected_error(err)
            end

            if #conf.anonymous > 1 then -- TODO
                return handle_anonymous(conf)
            end

            return kong.response.exit(401, { message = err })
        end

        -- if we here introspection was successful
        client_id = introspect_response.client_id
        exp = introspect_response.exp

        local consumer, err = kong.db.consumers:select_by_custom_id(client_id)
        if not consumer and not err then
            clear_pending_state(token)
            kong.log.err('consumer with custom_id "' .. client_id .. '" not found')
            return kong.response.exit(401, { message = "Unknown consumer" })
        end
        if err then
            clear_pending_state(token)
            return unexpected_error("select_by_custom_id error: ", err)
        end
        introspect_response.consumer = consumer

        kong.log.debug("save token in cache")
        worker_cache:set(token, introspect_response,
            exp - ngx.now() - EXPIRE_DELTA_SECONDS)
    else
        client_id = token_data.client_id
        exp = token_data.exp
    end

    -- Client(Consumer) is authenticated
    kong.ctx.shared.authenticated_consumer = token_data.consumer -- forward compatibility
    ngx.ctx.authenticated_consumer = token_data.consumer -- backward compatibility
    kong.ctx.shared[self.metric_client_authenticated] = true
    kong.ctx.shared.request_token_data = token_data -- Used to check wether token is authenticated or not for PEP plugin
    kong.ctx.shared.request_token = token -- May hide from autorization header so need it for PEP plugin
    return request_authenticated(conf, token_data)
end

--- Check requested path match to register path
-- @param request_path: Example: "/posts/one/two"
-- @param register_path: Example: "/posts"
-- @return boolean
function _M.is_path_match(request_path, register_path)
    assert(request_path)
    assert(register_path)

    if register_path == "/" then
        return true
    end

    if request_path == register_path then
        return true
    end

    local register_path_len = #register_path
    -- check is register_path a prefix of request_path
    if register_path ~= request_path:sub(1, register_path_len) then
        return false
    end

    -- check that prefix match is not partial
    if request_path:sub(register_path_len + 1, register_path_len + 1) == "/" then
        return true
    end

    -- we cannot have '?' in request_path, because we get it from ngx.var.uri
    -- it doesn't contain arguments

    return false
end

--- Check user valid UUID
-- @param anonymous: anonymous consumer id
function _M.check_user(anonymous)
    if anonymous == " " then
        return true
    end
    if utils.is_valid_uuid(anonymous) then
        local result, err = kong.db.consumers:select({ id = anonymous })
        if result then
            return true
        end
        if not err then
            err = 'consumer "' .. anonymous .. '" not found'
        end
        kong.log.err(err)
        return false
    end

    return false, "the anonymous user must be empty or a valid uuid"
end

--- Check OAuth and UMA scope expression
-- @param expression: JSON expression
function _M.check_expression(expression, config)
    if not expression or expression == cjson.null then
        -- it is possible that expression is not required, but this function is called
        return true
    end

    local paths = {}
    if #expression == 0 then
        return false, "Empty expression not allowed"
    end

    for k = 1, #expression do
        local item = expression[k]

        if not item.path or #item.path == 0 then
            return false, "Path is missing or empty in expression"
        end

        if pl_tablex.find(paths, item.path) then
            return false, "Duplicate path in expression"
        end
        table.insert(paths, item.path)

        if not item.conditions or #item.conditions == 0 then
            return false, "Conditions are missing in expression"
        end

        local http_methods = {}
        for i = 1, #item.conditions do
            local condition = item.conditions[i]

            if not condition.httpMethods or #condition.httpMethods == 0 then
                return false, "HTTP Methods are missing or empty from condition in expression"
            end

            for j = 1, #condition.httpMethods do
                if pl_tablex.find(http_methods, condition.httpMethods[j]) then
                    return false, "Duplicate http method from conditions in expression"
                end
            end
            http_methods = pl_tablex.merge(http_methods, condition.httpMethods, true)
        end
    end
    return true
end

-- @param exp: scope expression or acrs expression
function _M.convert_scope_expression_to_path_wildcard_tree(exp)
    if not exp or exp == cjson.null then
        -- it is possible that expression is not required, but this function is called
        return
    end

    local method_path_tree = {}

    for k = 1, #exp do
        local item = exp[k]

        for i = 1, #item.conditions do
            local condition = item.conditions[i]

            for j = 1, #condition.httpMethods do
                local t = { path = item.path }
                -- copy all conditions keys except httpMethods
                for k, v in pairs(condition) do
                    if k ~= "httpMethods" then
                        t[k] = v
                    end
                end
                path_wildcard_tree.addPath(method_path_tree, condition.httpMethods[j], item.path, t)
            end
        end
    end
    return method_path_tree
end

_M.get_protection_token = get_protection_token

function _M.get_body_data()
    -- explicitly read the req body
    ngx.req.read_body()

    local data = ngx.req.get_body_data()
    if not data then
        -- body may get buffered in a temp file:
        ngx.log(ngx.DEBUG, "loading client request body from a temp file")
        local filename = ngx.req.get_body_file()
        if not filename then
            print("no body found")
            return nil
        end
        -- this is really bad for performance
        data = assert(read_file(filename)) -- body should be here
    end
    return data
end

return _M
