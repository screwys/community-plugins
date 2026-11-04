--!nonstrict
-- CalDAV wire formats. Network and keyring access live in service.luau.
local model = require("./model.luau")
local dav = {}

local function trim(text) return text:match("^%s*(.-)%s*$") end

local function unxml(text)
    return (text:gsub("<!%[CDATA%[(.-)%]%]>", function(value) return value end):gsub("&(#?[%w]+);", function(entity)
        local named = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'" }
        if named[entity] then return named[entity] end
        local code = entity:sub(1, 2) == "#x" and tonumber(entity:sub(3), 16) or tonumber(entity:sub(2))
        return code and utf8.char(code) or ("&" .. entity .. ";")
    end))
end

-- Parse the XML tree rather than depending on the server's namespace prefixes.
function dav.xml(text, checkpoint)
    local root = { name = "", children = {}, text = "" }
    local stack = { root }
    local offset = 1
    while offset <= #text do
        local first, last, tag = text:find("<([^>]+)>", offset)
        local node = stack[#stack]
        node.text ..= unxml(text:sub(offset, first and first - 1 or #text))
        if first == nil then break end
        if tag:sub(1, 8) == "![CDATA[" then
            local finish = assert(text:find("]]>", first, true), "Invalid XML CDATA")
            node.text ..= text:sub(first + 9, finish - 1)
            last = finish + 2
        elseif tag:sub(1, 3) == "!--" then
            last = assert(text:find("-->", first, true), "Invalid XML comment") + 2
        elseif tag:sub(1, 1) == "/" then
            local name = tag:match("^/([^%s]+)")
            assert(#stack > 1 and node.tag == name, "Invalid XML closing tag")
            table.remove(stack)
        elseif tag:sub(1, 1) ~= "?" then
            assert(tag:sub(1, 1) ~= "!", "Unsupported XML declaration")
            local name = assert(tag:match("^([^%s/]+)"), "Invalid XML element")
            local child = { name = name:match("([^:]+)$"), tag = name, children = {}, text = "", attributes = {} }
            for key, quote, value in tag:gmatch("([%w_:.-]+)%s*=%s*(['\"])(.-)%2") do
                child.attributes[key] = unxml(value)
            end
            node.children[#node.children + 1] = child
            if tag:sub(-1) ~= "/" then stack[#stack + 1] = child end
        end
        offset = last + 1
        if checkpoint then checkpoint() end
    end
    assert(#stack == 1 and #root.children == 1, "Invalid XML document")
    return root.children[1]
end

function dav.find(node, name)
    for _, child in ipairs(node.children) do
        if child.name == name then return child end
    end
    return nil
end

function dav.properties(response)
    local result = {}
    for _, stat in ipairs(response.children) do
        if stat.name == "propstat" then
            local status = dav.find(stat, "status")
            local prop = dav.find(stat, "prop")
            if status and status.text:find(" 200 ", 1, true) and prop then
                for _, value in ipairs(prop.children) do result[value.name] = value end
            end
        end
    end
    return result
end

function dav.resolve(base, href)
    if href:match("^https?://") then return href end
    local origin = assert(base:match("^(https?://[^/]+)"), "Invalid server address")
    if href:sub(1, 1) == "/" then return origin .. href end
    return base:gsub("[^/]*$", "") .. href
end

local function unescape(value)
    return (value:gsub("\\(.)", function(ch) return (ch == "n" or ch == "N") and "\\n" or ch end))
end
local function escape(value)
    -- todo.txt represents embedded newlines with a literal backslash-n.
    return (value:gsub("\\n", "\n"):gsub("\\", "\\\\"):gsub("\n", "\\n"):gsub(";", "\\;"):gsub(",", "\\,"))
end
local function property(line)
    local quoted = false
    for index = 1, #line do
        local ch = line:sub(index, index)
        if ch == '"' then quoted = not quoted end
        if ch == ":" and not quoted then
            return line:sub(1, index - 1):match("^([^;]+)"):upper(), line:sub(index + 1)
        end
    end
    error("Invalid iCalendar property")
end
local function date(value)
    if value == nil then return nil end
    local y, m, d = value:match("^(%d%d%d%d)(%d%d)(%d%d)")
    return y and (y .. "-" .. m .. "-" .. d) or nil
end
local function tokenDate(title, token, value)
    local replacement = value and (token .. ":" .. value) or ""
    local changed, count = title:gsub("%f[%S]" .. token .. ":%S+", replacement)
    if count == 0 and value then changed ..= " " .. replacement end
    return trim(changed)
end

function dav.ical(text, checkpoint)
    local lines = {}
    text = text:gsub("\r\n", "\n"):gsub("\n[ \t]", "")
    for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local stack, candidate, master = {}, nil, nil
    for index, line in ipairs(lines) do
        if checkpoint then checkpoint() end
        local name, value = property(line)
        if name == "BEGIN" then
            stack[#stack + 1] = value:upper()
            if #stack == 2 and value:upper() == "VTODO" then
                candidate = { first = index, props = {}, indices = {} }
            end
        elseif name == "END" then
            assert(stack[#stack] == value:upper(), "Invalid iCalendar component")
            if #stack == 2 and candidate then
                if candidate.props["RECURRENCE-ID"] == nil then
                    assert(master == nil, "Multiple task masters in one resource")
                    candidate.last = index
                    master = candidate
                end
                candidate = nil
            end
            table.remove(stack)
        elseif #stack == 2 and candidate then
            candidate.props[name] = value
            candidate.indices[name] = index
        end
    end
    assert(master and #stack == 0 and master.props.UID, "Invalid VTODO resource")
    master.lines = lines
    return master
end

function dav.raw(ical)
    local p = ical.props
    local old = model.parse(unescape(p["X-TODOTXT-RAW"] or ""))
    local title = unescape(p.SUMMARY or "")
    title = tokenDate(title, "due", date(p.DUE))
    title = tokenDate(title, "t", date(p.DTSTART))
    local priority = tonumber(p.PRIORITY) or 0
    local letter = priority > 0 and string.char(64 + priority) or nil
    if old.priority and math.min(string.byte(old.priority) - 64, 9) == priority then letter = old.priority end
    local prefix = ""
    if p.STATUS == "COMPLETED" then prefix = "x " .. (date(p.COMPLETED) and (date(p.COMPLETED) .. " ") or "") end
    prefix ..= letter and ("(" .. letter .. ") ") or ""
    prefix ..= date(p.CREATED) and (date(p.CREATED) .. " ") or ""
    return prefix .. title
end

local function wireDate(value, utc)
    return value and (value:gsub("%-", "") .. (utc and "T000000Z" or "")) or nil
end

function dav.encode(raw, previous, position, uid)
    local source = previous and dav.ical(previous) or { lines = { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Noctalia//todo.txt//EN", "BEGIN:VTODO", "END:VTODO", "END:VCALENDAR" }, first = 4, last = 5, props = {}, indices = {} }
    local old = previous and model.parse(dav.raw(source)) or {}
    local task = model.parse(raw)
    local changes = {}
    local function put(name, value) changes[name] = value or false end
    if not previous then put("UID", uid) end
    if task.title ~= old.title then put("SUMMARY", escape(task.title)) end
    for _, pair in ipairs({ { "creationDate", "CREATED" }, { "completionDate", "COMPLETED" }, { "due", "DUE" }, { "threshold", "DTSTART" } }) do
        if task[pair[1]] ~= old[pair[1]] then put(pair[2], wireDate(task[pair[1]], pair[2] == "CREATED" or pair[2] == "COMPLETED")) end
    end
    if task.completed ~= old.completed then
        put("STATUS", task.completed and "COMPLETED" or "NEEDS-ACTION")
        put("PERCENT-COMPLETE", task.completed and "100" or "0")
    end
    if task.priority ~= old.priority then put("PRIORITY", tostring(task.priority and math.min(string.byte(task.priority) - 64, 9) or 0)) end
    put("X-TODOTXT-RAW", escape(raw))
    put("X-TODOTXT-POSITION", tostring(position))
    put("DTSTAMP", os.date("!%Y%m%dT%H%M%SZ"))
    local output = {}
    for index, line in ipairs(source.lines) do
        if index == source.last then
            local names = {}
            for name in pairs(changes) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local value = changes[name]
                if value ~= false then
                    local parameter = (name == "DUE" or name == "DTSTART") and ";VALUE=DATE" or ""
                    output[#output + 1] = name .. parameter .. ":" .. value
                end
            end
        end
        local name = index > source.first and index < source.last and property(line) or nil
        if name == nil or changes[name] == nil or source.indices[name] ~= index then output[#output + 1] = line end
    end
    local folded = {}
    for _, line in ipairs(output) do
        while #line > 75 do
            local at = 75
            while string.byte(line, at + 1) >= 128 and string.byte(line, at + 1) < 192 do at -= 1 end
            folded[#folded + 1] = line:sub(1, at)
            line = " " .. line:sub(at + 1)
        end
        folded[#folded + 1] = line
    end
    return table.concat(folded, "\r\n") .. "\r\n"
end

return dav
