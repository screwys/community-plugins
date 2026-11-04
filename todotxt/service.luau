--!nonstrict
local dav = require("./caldav.luau")
local model = require("./model.luau")
local function configuredAccount()
    if noctalia.getConfig("storage") ~= "caldav" then return { enabled = false } end
    local accounts = noctalia.getSetting("calendar.account") or {}
    local id = noctalia.getConfig("caldav_account") or ""
    if id == "" then
        for candidate, value in pairs(accounts) do
            if value.type == "caldav" then
                if id ~= "" then return { enabled = true }, noctalia.tr("remote_choose_account") end
                id = candidate
            end
        end
    end
    local native = accounts[id]
    if native == nil or native.type ~= "caldav" then
        return { enabled = true }, noctalia.tr("remote_account_missing")
    end
    if native.client_cert_file and native.client_cert_file ~= "" then
        return { enabled = true }, noctalia.tr("remote_client_certificate")
    end
    local collection = noctalia.getConfig("caldav_calendar") or ""
    return {
        enabled = true, id = id, username = native.username,
        url = (native.provider == "icloud" and "https://caldav.icloud.com/" or native.server_url):gsub("/*$", "/"),
        collection = collection, calendars = native.calendars or {},
        credentialSource = native.credential_source or "secret-service", passwordFile = native.password_file,
    }
end
local account, configurationError = configuredAccount()
local generation = 0
local password = nil
local records = {}
local revision = 0
local busy = false
local errorText = configurationError
local needsPassword = false
local collections = {}
local lastRequest = nil
local lastSuccess = false
local ids, nextId = {}, 1
local refresh
local work = nil

local function schedule(action)
    work = coroutine.create(action)
    noctalia.setUpdateInterval(16)
end

local function publish()
    local tasks = {}
    for _, record in ipairs(records) do tasks[#tasks + 1] = { id = record.id, raw = record.raw } end
    noctalia.state.set("todotxt.remote", {
        enabled = account.enabled == true, account = account, tasks = tasks,
        revision = revision, busy = busy, error = errorText,
        needsPassword = needsPassword, collections = collections,
        request = lastRequest, success = lastSuccess,
    })
end

local function finish(err)
    busy = false
    errorText = err
    publish()
end

local function request(method, url, body, headers, callback)
    local activeGeneration = generation
    local origin = account.url:match("^(https?://[^/]+)")
    if url:sub(1, #(origin or "")) ~= origin or url:sub(#origin + 1, #origin + 1) ~= "/" then
        callback(nil, noctalia.tr("remote_origin")); return
    end
    local accepted = noctalia.http({
        url = url, method = method, body = body,
        headers = headers, basic_username = account.username, basic_password = password,
    }, function(response)
        if activeGeneration ~= generation then return end
        if response.ok and response.status >= 200 and response.status < 300 then callback(response.body, nil)
        else
            if response.status == 401 then needsPassword = true; password = nil end
            callback(nil, response.status == 412 and noctalia.tr("remote_conflict") or noctalia.tr("remote_http", { status = response.status }))
        end
    end)
    if not accepted then callback(nil, noctalia.tr("remote_unavailable")) end
end

local function propfind(url, props, depth, callback)
    request("PROPFIND", url, '<d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop>' .. props .. '</d:prop></d:propfind>',
        { "Depth: " .. depth, "Content-Type: application/xml; charset=utf-8" }, function(body, err)
        if body == nil then callback(nil, err); return end
        local ok, root = pcall(dav.xml, body)
        if not ok then callback(nil, noctalia.tr("remote_invalid")); return end
        callback(root, nil)
    end)
end

local function propertyHref(root, name)
    for _, response in ipairs(root.children) do
        if response.name == "response" then
            local node = dav.properties(response)[name]
            local href = node and dav.find(node, "href")
            if href then return href.text end
        end
    end
    return nil
end

local function discover(callback)
    propfind(account.url, "<d:current-user-principal/>", "0", function(root, err)
        if root == nil then callback(nil, err); return end
        local href = propertyHref(root, "current-user-principal")
        if href == nil then callback(nil, noctalia.tr("remote_principal")); return end
        local principal = dav.resolve(account.url, href)
        propfind(principal, "<c:calendar-home-set/>", "0", function(homeRoot, homeErr)
            if homeRoot == nil then callback(nil, homeErr); return end
            local home = propertyHref(homeRoot, "calendar-home-set")
            if home == nil then callback(nil, noctalia.tr("remote_home")); return end
            local homeUrl = dav.resolve(principal, home)
            propfind(homeUrl, "<d:resourcetype/><d:displayname/><c:supported-calendar-component-set/>", "1", function(list, listErr)
                if list == nil then callback(nil, listErr); return end
                collections = {}
                for _, response in ipairs(list.children) do
                    if response.name == "response" then
                        local props = dav.properties(response)
                        local components = props["supported-calendar-component-set"]
                        local supportsTasks = components == nil
                        if components then
                            for _, comp in ipairs(components.children) do
                                if comp.attributes.name == "VTODO" then supportsTasks = true end
                            end
                        end
                        local hrefNode = dav.find(response, "href")
                        if supportsTasks and props.resourcetype and dav.find(props.resourcetype, "calendar") and hrefNode then
                            local url = dav.resolve(homeUrl, hrefNode.text)
                            local collectionId = noctalia.string.urlDecode(url:gsub("/+$", ""):match("([^/]+)$") or "")
                            if #account.calendars == 0 or table.find(account.calendars, collectionId) then
                                collections[#collections + 1] = { url = url, name = props.displayname and props.displayname.text or url }
                            end
                        end
                    end
                end
                if #collections == 1 then
                    account.collection = collections[1].url
                    callback(account.collection, nil)
                else callback(nil, noctalia.tr(#collections == 0 and "remote_no_calendar" or "remote_choose_calendar")) end
            end)
        end)
    end)
end

local function read(callback)
    local query = '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:getetag/><c:calendar-data/></d:prop><c:filter><c:comp-filter name="VCALENDAR"><c:comp-filter name="VTODO"/></c:comp-filter></c:filter></c:calendar-query>'
    request("REPORT", account.collection, query, { "Depth: 1", "Content-Type: application/xml; charset=utf-8" }, function(body, err)
        if body == nil then callback(err); return end
        schedule(function()
            local ok, loaded = pcall(function()
                local result = {}
                local root = dav.xml(body, coroutine.yield)
                assert(root.name == "multistatus")
                for _, response in ipairs(root.children) do
                    if response.name == "response" then
                        local props = dav.properties(response)
                        if props["calendar-data"] then
                            local ical = props["calendar-data"].text
                            local parsed = dav.ical(ical, coroutine.yield)
                            local href = assert(dav.find(response, "href")).text
                            local etag = assert(props.getetag).text
                            assert(etag ~= "")
                            if ids[href] == nil then ids[href] = nextId; nextId += 1 end
                            result[#result + 1] = { id = ids[href], href = href, etag = etag, ical = ical,
                                raw = dav.raw(parsed), position = tonumber(parsed.props["X-TODOTXT-POSITION"]) or 2147483647 }
                        end
                    end
                end
                table.sort(result, function(a, b)
                    if a.position ~= b.position then return a.position < b.position end
                    return a.href < b.href
                end)
                return result
            end)
            if not ok then noctalia.log("CalDAV parse error: " .. tostring(loaded)); callback(noctalia.tr("remote_invalid")); return end
            local changed = #loaded ~= #records
            if not changed then
                for i, row in ipairs(loaded) do
                    if records[i].href ~= row.href or records[i].etag ~= row.etag then changed = true; break end
                end
            end
            records = loaded
            if changed then revision += 1 end
            callback(nil)
        end)
    end)
end

local function lookup(callback)
    local activeGeneration = generation
    if account.credentialSource == "file" then
        local accepted = noctalia.readFileAsync(account.passwordFile, function(value, _err)
            if activeGeneration ~= generation then return end
            if value then value = value:gsub("\r?\n$", "") end
            if value == nil or value == "" or #value > 65536 or value:find("%z") then
                callback(noctalia.tr("remote_password_file")); return
            end
            password = value
            needsPassword = false
            callback(nil)
        end)
        if not accepted then callback(noctalia.tr("remote_unavailable")) end
        return
    end
    if not noctalia.commandExists("secret-tool") then callback(noctalia.tr("remote_keyring_missing")); return end
    local accepted = noctalia.runAsync({ "secret-tool", "lookup", "application", "noctalia", "scope", "calendar", "owner", account.id, "name", "password", "version", "1" }, function(result)
        if activeGeneration ~= generation then return end
        if result.exitCode ~= 0 or result.stdout == "" or result.stdoutTruncated then
            needsPassword = true
            callback(noctalia.tr("remote_password")); return
        end
        password = result.stdout:gsub("\n$", "")
        needsPassword = false
        callback(nil)
    end, 60000)
    if not accepted then callback(noctalia.tr("remote_unavailable")) end
end

refresh = function()
    if busy or not account.enabled or configurationError then return end
    if noctalia.getSetting("shell.offline_mode") == true then finish(noctalia.tr("remote_offline")); return end
    busy = true
    errorText = nil
    publish()
    local function connected(err)
        if err then finish(err); return end
        if account.collection and account.collection ~= "" then read(finish)
        else discover(function(url, discoveryErr)
            if url then read(finish) else finish(discoveryErr) end
        end) end
    end
    if password and account.credentialSource ~= "file" then connected(nil) else lookup(connected) end
end

local function save(command)
    if command.revision ~= revision then finish(noctalia.tr("remote_conflict")); return end
    local byId, kept, operations = {}, {}, {}
    for _, row in ipairs(records) do byId[row.id] = row end
    for position, task in ipairs(command.tasks) do
        coroutine.yield()
        local previous = byId[task.id]
        kept[task.id] = true
        if previous == nil or previous.raw ~= task.raw or previous.position ~= position - 1 then
            local uid = tostring(noctalia.nowMs()) .. "-" .. tostring(task.id) .. "-" .. tostring(math.random(1, 1000000000)) .. "@noctalia"
            operations[#operations + 1] = {
                method = "PUT", url = previous and dav.resolve(account.collection, previous.href) or (account.collection:gsub("/*$", "/") .. uid .. ".ics"),
                body = dav.encode(task.raw, previous and previous.ical, position - 1, uid),
                headers = { "Content-Type: text/calendar; charset=utf-8", previous and ("If-Match: " .. previous.etag) or "If-None-Match: *" },
            }
        end
    end
    for _, row in ipairs(records) do
        if not kept[row.id] then operations[#operations + 1] = { method = "DELETE", url = dav.resolve(account.collection, row.href), headers = { "If-Match: " .. row.etag } } end
    end
    local function step(index)
        local operation = operations[index]
        if operation == nil then
            read(function(err)
                lastSuccess = err == nil
                finish(err)
            end)
            return
        end
        request(operation.method, operation.url, operation.body, operation.headers, function(_body, err)
            if err then read(function(_readErr) finish(err) end)
            else step(index + 1) end
        end)
    end
    step(1)
end

noctalia.state.watch("todotxt.request", function(command)
    if type(command) ~= "table" then return end
    noctalia.state.set("todotxt.request", nil)
    if busy then return end
    busy = true
    lastRequest = command.id
    lastSuccess = false
    errorText = nil
    publish()
    if command.action == "save" then
        schedule(function() save(command) end)
    else busy = false; refresh() end
end)

function update()
    if work then
        local started = noctalia.nowMs()
        while work and noctalia.nowMs() - started < 3 do
            local current = work
            local ok, err = coroutine.resume(current)
            if not ok then
                work = nil
                noctalia.log("CalDAV processing error: " .. tostring(err))
                finish(noctalia.tr("remote_invalid"))
            elseif coroutine.status(current) == "dead" and work == current then work = nil end
        end
        if work == nil then noctalia.setUpdateInterval(30000) end
    else
        refresh()
    end
end
noctalia.setUpdateInterval(30000)
publish()
refresh()

function onIpc(event)
    if event == "refresh" then refresh()
    elseif event == "status" then
        noctalia.log("CalDAV: " .. tostring(#records) .. " tasks, " .. (busy and "syncing" or "idle") .. (errorText and (", " .. errorText) or ""))
    end
end

function onConfigChanged()
    generation += 1
    work, password, busy = nil, nil, false
    account, configurationError = configuredAccount()
    records, ids, nextId, collections = {}, {}, 1, {}
    revision += 1
    errorText = configurationError
    publish()
    refresh()
end
