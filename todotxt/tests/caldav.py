from pathlib import Path
import subprocess
import sys
import tempfile
# Usage: python3 todotxt/tests/caldav.py /path/to/luau
root=Path(__file__).resolve().parent.parent
model=(root/'model.luau').read_text()
protocol=(root/'caldav.luau').read_text().replace('local model = require("./model.luau")','')
tests=r'''
for _, raw in ipairs({
 '(A) 2026-10-01 Call +health @phone due:2026-11-12 later t:2026-11-01 rec:1w',
 'x 2026-11-01 (Z) 2026-10-01 Done', 'Unicode ş 你好, semicolon; colon: slash\\ and\\nnext',
 'x No completion date', 'No dates', '(I) Priority nine', string.rep('ş', 80),
}) do
 local encoded = dav.encode(raw, nil, 0, 'fixture')
 assert(dav.raw(dav.ical(encoded)) == raw, 'Roundtrip: ' .. raw .. ' became ' .. dav.raw(dav.ical(encoded)))
end
local base = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:one\r\nSUMMARY:Native\r\nDUE;TZID=Europe/Istanbul:20261117T120000\r\nRRULE:FREQ=WEEKLY\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nSUMMARY:Alarm\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VTODO\r\nBEGIN:VTODO\r\nUID:one\r\nRECURRENCE-ID:20261110T120000Z\r\nSUMMARY:Exception\r\nEND:VTODO\r\nEND:VCALENDAR\r\n'
local updated = dav.encode('Edited due:2026-11-17', base, 1)
assert(updated:find('SUMMARY:Edited', 1, true))
assert(updated:find('DUE;TZID=Europe/Istanbul:20261117T120000', 1, true))
assert(updated:find('RRULE:FREQ=WEEKLY', 1, true))
assert(updated:find('SUMMARY:Alarm', 1, true))
assert(updated:find('SUMMARY:Exception', 1, true))
local changed = dav.encode('Edited due:2026-11-18', base, 1)
assert(changed:find('DUE;VALUE=DATE:20261118', 1, true))
assert(not changed:find('DUE;TZID', 1, true))
local root=dav.xml('<x:multistatus xmlns:x="DAV:"><x:response><x:href>/one&amp;two</x:href><x:propstat><x:prop><z:calendar-data xmlns:z="urn:ietf:params:xml:ns:caldav"><![CDATA[one < two & three]]></z:calendar-data><x:getetag>&quot;e&#x31;&quot;</x:getetag></x:prop><x:status>HTTP/1.1 200 OK</x:status></x:propstat></x:response></x:multistatus>')
local props = dav.properties(root.children[1])
assert(props.getetag.text == '"e1"')
assert(props['calendar-data'].text == 'one < two & three')
assert(dav.find(root.children[1], 'href').text == '/one&two')
local quoted=dav.xml('<c:comp xmlns:c="urn:ietf:params:xml:ns:caldav" name="VTODO"/>')
assert(quoted.attributes.name == 'VTODO')
assert(not pcall(dav.xml, '<a><b></a>'))
assert(not pcall(dav.ical, 'BEGIN:VCALENDAR\r\nEND:VCALENDAR'))
print('CalDAV conversion, Unicode folding, XML, alarms, recurrence and external edits passed.')
'''
service_tests = r'''
local handlers, states, files = {}, {}, {}
local nativeAccount = { type = "caldav", server_url = "https://example.test/", username = "user", credential_source = "secret-service" }
local database = { ["https://example.test/tasks/one.ics"] = { body = dav.encode("One", nil, 0, "one"), etag = '"1"' } }
local calls, lookups, sequence = {}, 0, 1
local function xml(value) return (value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function report()
    local chunks = { '<d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">' }
    for url, item in pairs(database) do
        chunks[#chunks + 1] = '<d:response><d:href>' .. url .. '</d:href><d:propstat><d:prop><d:getetag>' .. xml(item.etag) .. '</d:getetag><c:calendar-data>' .. xml(item.body) .. '</c:calendar-data></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>'
    end
    return table.concat(chunks) .. '</d:multistatus>'
end
local clock = 0
noctalia = {
    string = noctalia.string,
    pluginDataDir = function() return "/fixture" end,
    getConfig = function(key)
        return ({ storage = "caldav", caldav_account = "native_account", caldav_calendar = "https://example.test/tasks/" })[key]
    end,
    getSetting = function(key)
        if key == "shell.offline_mode" then return false end
        return { native_account = nativeAccount }
    end,
    readFileAsync = function(path, callback) callback(files[path], nil); return true end,
    writeFile = function(path, content) files[path] = content; return true end,
    removeFile = function(path) files[path] = nil; return true end,
    tr = function(key) return key end, log = function(value) print(value) end,
    setUpdateInterval = function() end,
    nowMs = function() clock += 1; return clock end,
    commandExists = function() return true end,
    state = {
        set = function(key, value) states[key] = value end,
        watch = function(key, handler) handlers[key] = handler end,
    },
    runAsync = function(argv, callback)
        for _, value in ipairs(argv) do assert(not value:find("fixture-password", 1, true), "Password leaked into arguments") end
        if argv[1] == "secret-tool" then lookups += 1; callback({ exitCode = 0, stdout = "fixture-password\n" })
            assert(argv[3] == "application" and argv[4] == "noctalia" and argv[8] == "native_account")
        else error("Unexpected keyring command") end
        return true
    end,
    http = function(request, callback)
        calls[#calls + 1] = request
        local item = database[request.url]
        local status, body = 200, ""
        if request.method == "REPORT" then body = report()
        elseif request.method == "PUT" then
            local expected = item and ("If-Match: " .. item.etag) or "If-None-Match: *"
            assert(request.headers[2] ~= nil)
            if request.headers[2] ~= expected then status = 412
            else sequence += 1; database[request.url] = { body = request.body, etag = '\"' .. sequence .. '\"' } end
        elseif request.method == "DELETE" then
            if not item or request.headers[1] ~= "If-Match: " .. item.etag then status = 412
            else database[request.url] = nil end
        else error("Unexpected HTTP method") end
        callback({ ok = true, status = status, body = body })
        return true
    end,
}
'''
service = (root/'service.luau').read_text().replace('local dav = require("./caldav.luau")','').replace('local model = require("./model.luau")','')
service_assertions = r'''
local function drain()
    for _ = 1, 10000 do
        if not states["todotxt.remote"].busy then return end
        update()
    end
    error("Service did not finish")
end
local function send(command)
    handlers["todotxt.request"](command)
    drain()
    return states["todotxt.remote"]
end
drain()
local state = states["todotxt.remote"]
assert(#state.tasks == 1 and state.tasks[1].raw == "One")
assert(lookups == 1)
state = send({ id = "create", action = "save", revision = state.revision, tasks = { {id = 1, raw = "Changed"}, {id = 2, raw = "New"} } })
assert(state.success and #state.tasks == 2 and state.tasks[1].raw == "Changed")
assert(lookups == 1, "Keyring lookup repeated during save")
state = send({ id = "delete", action = "save", revision = state.revision, tasks = { state.tasks[1] } })
assert(state.success and #state.tasks == 1)
local original = database["https://example.test/tasks/one.ics"].body
database["https://example.test/tasks/one.ics"].etag = '"external"'
state = send({ id = "conflict", action = "save", revision = state.revision, tasks = { {id = 1, raw = "Stale edit"} } })
assert(not state.success and state.error == "remote_conflict")
assert(database["https://example.test/tasks/one.ics"].body == original)
local previousLookups = lookups
nativeAccount.credential_source = "file"
nativeAccount.password_file = "/fixture/native-password"
files["/fixture/native-password"] = "file-fixture\r\n"
onConfigChanged()
drain()
assert(lookups == previousLookups)
assert(calls[#calls].basic_password == "file-fixture")
assert(#states["todotxt.remote"].tasks == 1)
print("Service CRUD, conflicts and native keyring/file credentials passed.")
'''
out='local noctalia = { string = { trim = function(value) return value:match("^%s*(.-)%s*$") end } }\nlocal model = (function()\n'+model+'\nend)()\nlocal dav = (function()\n'+protocol+'\nend)()\n'+tests+service_tests+'\nlocal service = (function()\n'+service+'\nend)()\n'+service_assertions
with tempfile.TemporaryDirectory(prefix='todotxt-tests-') as directory:
    path=Path(directory)/'tests.luau'
    path.write_text(out)
    subprocess.run([sys.argv[1] if len(sys.argv)>1 else 'luau', str(path)],check=True)
