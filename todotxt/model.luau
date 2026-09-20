--!nonstrict

local model = {}

local function trim(value)
    return noctalia.string.trim(value or "")
end

local function dateToken(value)
    return type(value) == "string" and value:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

local function copyList(values)
    local result = {}
    for i, value in ipairs(values or {}) do
        result[i] = value
    end
    return result
end

function model.defaultPath()
    local configured = trim(noctalia.getConfig("todo_file"))
    if configured ~= "" then
        return noctalia.expandPath(configured)
    end
    local directory = noctalia.pluginDataDir()
    return directory .. "/todo.txt"
end

function model.parse(line, id, compact)
    local raw = line or ""
    local scan = raw
    local task = {
        id = id,
        raw = raw,
        completed = false,
        completionDate = nil,
        creationDate = nil,
        priority = nil,
        title = scan,
        search = string.lower(scan),
        projects = {},
        contexts = {},
        due = nil,
        threshold = nil,
    }

    local rest = scan
    local completedDate, afterCompleted = rest:match("^x%s+(%d%d%d%d%-%d%d%-%d%d)%s+(.+)$")
    if completedDate ~= nil then
        task.completed = true
        task.completionDate = completedDate
        rest = afterCompleted
    elseif rest:match("^x%s+") then
        task.completed = true
        rest = rest:gsub("^x%s+", "", 1)
    end

    local priority, afterPriority = rest:match("^%(([A-Z])%)%s+(.+)$")
    if priority ~= nil then
        task.priority = priority
        rest = afterPriority
    end

    local first, afterFirst = rest:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(.+)$")
    if first ~= nil then
        task.creationDate = first
        rest = afterFirst
    end

    if not compact then
        for token in rest:gmatch("[+@][%w_.%-]+") do
            if token:sub(1, 1) == "+" then
                task.projects[#task.projects + 1] = token:sub(2)
            else
                task.contexts[#task.contexts + 1] = token:sub(2)
            end
        end
    end
    task.due = rest:match("%f[%w]due:(%d%d%d%d%-%d%d%-%d%d)%f[%W]")
    task.threshold = rest:match("%f[%w]t:(%d%d%d%d%-%d%d%-%d%d)%f[%W]")

    task.title = trim(rest)
    if task.title == "" then
        task.title = rest
    end
    return task
end

function model.readText(raw, compact)
    local tasks = {}
    if raw == nil or raw == "" then
        return tasks
    end
    if raw:find("\r", 1, true) ~= nil then
        raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
    end
    local id = 0
    for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            id += 1
            tasks[#tasks + 1] = model.parse(line, id, compact)
        end
    end
    return tasks
end

function model.read(path)
    return model.readText(noctalia.readFile(path))
end

function model.serialize(tasks)
    local lines = {}
    for _, task in ipairs(tasks) do
        local line = task.raw or ""
        if line ~= "" then
            lines[#lines + 1] = line
        end
    end
    if #lines == 0 then
        return ""
    end
    return table.concat(lines, "\n") .. "\n"
end

function model.write(path, tasks)
    local parent = path:match("^(.*)/[^/]+$")
    if parent ~= nil and parent ~= "" then
        local ok, err = noctalia.mkdirAll(parent)
        if not ok then
            return false, err
        end
    end
    local previous = noctalia.readFile(path)
    if previous ~= nil then
        local backedUp, backupErr = noctalia.writeFile(path .. ".bak", previous)
        if not backedUp then
            return false, backupErr
        end
    end
    local temporary = path .. ".todotxt.tmp"
    local ok, err = noctalia.writeFile(temporary, model.serialize(tasks))
    if not ok then
        return false, err
    end
    local renamed, renameErr = noctalia.renameFile(temporary, path)
    if not renamed then
        return false, renameErr
    end
    return true, nil
end

function model.today()
    return os.date("%Y-%m-%d")
end

function model.newLine(text, addCreationDate)
    local value = trim(text)
    if value == "" then
        return ""
    end
    if not addCreationDate or value:match("^x%s+") or value:match("^%([A-Z]%)%s+%d%d%d%d%-%d%d%-%d%d%s+") or value:match("^%d%d%d%d%-%d%d%-%d%d%s+") then
        return value
    end
    local priority, body = value:match("^(%([A-Z]%)%s+)(.+)$")
    if priority ~= nil then
        return priority .. model.today() .. " " .. body
    end
    return model.today() .. " " .. value
end

function model.setCompleted(task, completed)
    if task.completed == completed then
        return task.raw
    end
    if completed then
        return "x " .. model.today() .. " " .. task.raw
    end
    local value = task.raw:gsub("^x%s+%d%d%d%d%-%d%d%-%d%d%s+", "", 1)
    return value:gsub("^x%s+", "", 1)
end

function model.setPriority(task, priority)
    local value = task.raw
    if task.completed then
        local prefix, rest = value:match("^(x%s+%d%d%d%d%-%d%d%-%d%d%s+)(.+)$")
        if prefix ~= nil then
            rest = rest:gsub("^%([A-Z]%)%s+", "", 1)
            return prefix .. (priority ~= nil and "(" .. priority .. ") " or "") .. rest
        end
    end
    value = value:gsub("^%([A-Z]%)%s+", "", 1)
    return (priority ~= nil and "(" .. priority .. ") " or "") .. value
end

function model.setTitle(task, title)
    local value = trim(title)
    if value == "" then return task.raw end
    local first, last = string.find(task.raw, task.title, 1, true)
    if first ~= nil then
        return task.raw:sub(1, first - 1) .. value .. task.raw:sub(last + 1)
    end
    local prefix = ""
    if task.completed then
        prefix = task.completionDate ~= nil and ("x " .. task.completionDate .. " ") or "x "
    end
    if task.priority ~= nil then
        prefix = prefix .. "(" .. task.priority .. ") "
    end
    if task.creationDate ~= nil then
        prefix = prefix .. task.creationDate .. " "
    end
    return prefix .. value
end

function model.setProject(task, project)
    local value = trim(project):gsub("^%+", ""):gsub("%s+", "-"):gsub("[^%w_.%-]", "")
    local replacement = value ~= "" and " +" .. value or ""
    local updated, count = task.raw:gsub("%s+%+[%w_.%-]+", replacement, 1)
    if count == 0 and replacement ~= "" then updated = updated .. replacement end
    return updated
end

function model.setContext(task, context)
    local value = trim(context):gsub("^@", ""):gsub("%s+", "-"):gsub("[^%w_.%-]", "")
    local replacement = value ~= "" and " @" .. value or ""
    local updated, count = task.raw:gsub("%s+@[%w_.%-]+", replacement, 1)
    if count == 0 and replacement ~= "" then updated = updated .. replacement end
    return updated
end

function model.setDue(task, due)
    local value = trim(due):gsub("^due:", "")
    local replacement = value ~= "" and " due:" .. value or ""
    local updated, count = task.raw:gsub("%s+due:%S+", replacement, 1)
    if count == 0 and replacement ~= "" then updated = updated .. replacement end
    return updated
end

function model.setCreationDate(task, date)
    local value = trim(date)
    local prefix = ""
    local rest = task.raw
    local completedPrefix, afterCompleted = rest:match("^(x%s+%d%d%d%d%-%d%d%-%d%d%s+)(.+)$")
    if completedPrefix ~= nil then prefix, rest = completedPrefix, afterCompleted end
    local priorityPrefix, afterPriority = rest:match("^(%([A-Z]%)%s+)(.+)$")
    if priorityPrefix ~= nil then prefix, rest = prefix .. priorityPrefix, afterPriority end
    rest = rest:gsub("^%d%d%d%d%-%d%d%-%d%d%s+", "", 1)
    if value == "" then return prefix .. rest end
    return prefix .. value .. " " .. rest
end

function model.copyTags(task)
    return copyList(task.projects), copyList(task.contexts)
end

function model.stamp(path)
    local info = noctalia.fileInfo(path)
    if type(info) ~= "table" then
        return "missing"
    end
    return tostring(info.mtime or "") .. ":" .. tostring(info.size or "")
end

function model.isDate(value)
    return dateToken(value)
end

return model
