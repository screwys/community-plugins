--!nonstrict

local model = require("./model.luau")
local remote = noctalia.state.get("todotxt.remote") or {}
local remoteRevision = -1
local pendingRemote = nil
local commandSerial = 0
local opened = false

local DRAG_TYPE = "todotxt-task"
local PRIORITIES = { "A", "B", "C" }
local STATUS_OPTIONS = { "status_open", "status_all", "status_done" }
local PRIORITY_OPTIONS = { "priority_any", "A", "B", "C", "priority_none" }
local SORT_OPTIONS = { "sort_manual", "sort_priority", "sort_due" }
local STATUS_GLYPHS = { "circle", "list", "checks" }
local SORT_GLYPHS = { "arrows-sort", "sort-ascending", "calendar" }

local PANEL_WIDTH = 585
local PANEL_PADDING = 14
local SCROLLBAR_GUTTER = 14
local SCROLL_PADDING = 4
local CARD_PADDING = 6
local CARD_BORDER = 1
local ROW_GAP = 6
local GRIP_WIDTH = 20
local PRIORITY_WIDTH = 14
local DONE_WIDTH = 32
local DATE_WIDTH = 90
local ACTION_WIDTH = 30
local ACTIONS_WIDTH = ACTION_WIDTH * 3
local TRAILING_SPACE = 12
local ROW_CONTENT_WIDTH = PANEL_WIDTH - (2 * PANEL_PADDING) - SCROLLBAR_GUTTER - (2 * SCROLL_PADDING)
local MAIN_WIDTH = ROW_CONTENT_WIDTH
    - (2 * CARD_PADDING)
    - (2 * CARD_BORDER)
    - (6 * ROW_GAP)
    - GRIP_WIDTH
    - PRIORITY_WIDTH
    - DONE_WIDTH
    - DATE_WIDTH
    - ACTIONS_WIDTH
    - TRAILING_SPACE

local tasks = {}
local todoPath = ""
local diskStamp = ""
local nextId = 1

local query = ""
local statusIndex = 0
local priorityIndex = 0
local sortIndex = 0
local tagFilter = ""
local tagValues = { "" }

local selectedId = nil
local adding = false
local addDraft = ""
local editingId = nil
local editingField = nil
local editDraft = ""
local deleteId = nil
local deleteChoice = 0
local confirmingClear = false
local showHelp = false
local focusSearch = false
local searchActive = false
local searchRev = 0

local function tr(key, args)
    return noctalia.tr(key, args)
end

local function trim(value)
    return noctalia.string.trim(value or "")
end

local function lower(value)
    return string.lower(value or "")
end

local function shorten(value, limit)
    if value == nil or value == "" then return "" end
    local display = value:gsub("\\n", " "):gsub("[\r\n]+", " ")
    local length = utf8.len(display)
    if length == nil or length <= limit then return display end
    local finish = utf8.offset(display, limit + 1)
    if finish == nil then return display end
    return display:sub(1, finish - 1) .. "…"
end

local function findTask(id)
    for index, task in ipairs(tasks) do
        if task.id == id then
            return task, index
        end
    end
    return nil, nil
end

local function parseAt(index, raw, id)
    tasks[index] = model.parse(raw, id)
end

local function publishChange()
    noctalia.state.set("todotxt.changed", tostring(os.time()) .. ":" .. tostring(#tasks))
end

local function saveTasks()
    if remote.enabled then
        if remote.busy or pendingRemote then return false end
        local recovery = noctalia.pluginDataDir() .. "/caldav-unsaved.txt"
        local ok, err = model.write(recovery, tasks)
        if not ok then noctalia.notifyError(tr("title"), err); return false end
        commandSerial += 1
        pendingRemote = "save-" .. tostring(os.time()) .. "-" .. commandSerial
        local rows = {}
        for _, task in ipairs(tasks) do
            if not task.transient then rows[#rows + 1] = { id = task.id, raw = task.raw } end
        end
        noctalia.state.set("todotxt.request", { id = pendingRemote, action = "save", revision = remoteRevision, tasks = rows })
        return true
    end
    local ok, err = model.write(todoPath, tasks)
    if not ok then
        noctalia.notifyError(tr("title"), err or tr("save_failed"))
        return false
    end
    diskStamp = model.stamp(todoPath)
    publishChange()
    return true
end

local function loadTasks()
    if remote.enabled then
        tasks = {}
        for _, row in ipairs(remote.tasks or {}) do tasks[#tasks + 1] = model.parse(row.raw, row.id) end
        remoteRevision = remote.revision or 0
    else tasks = model.read(todoPath) end
    nextId = 1
    for _, task in ipairs(tasks) do nextId = math.max(nextId, task.id + 1) end
    diskStamp = model.stamp(todoPath)
    selectedId = nil
end

local function priorityRank(priority)
    if priority == "A" then return 1 end
    if priority == "B" then return 2 end
    if priority == "C" then return 3 end
    return 4
end

local function matchesTag(task)
    if tagFilter == "" then
        return true
    end
    local wanted = tagFilter:sub(2)
    for _, value in ipairs(task.projects) do
        if value == wanted then
            return true
        end
    end
    return false
end

local function matchesFilters(task)
    if task.transient then return true end
    if statusIndex == 0 and task.completed then return false end
    if statusIndex == 2 and not task.completed then return false end

    if priorityIndex > 0 then
        local wanted = priorityIndex <= 3 and PRIORITIES[priorityIndex] or nil
        if priorityIndex == 4 then
            if task.priority ~= nil then return false end
        elseif task.priority ~= wanted then
            return false
        end
    end

    if not matchesTag(task) then return false end
    local needle = lower(trim(query))
    return needle == "" or string.find(task.search or lower(task.title), needle, 1, true) ~= nil
end

local function visibleTasks()
    local visible = {}
    for index, task in ipairs(tasks) do
        if matchesFilters(task) then
            visible[#visible + 1] = { task = task, sourceIndex = index }
        end
    end
    if sortIndex == 1 then
        table.sort(visible, function(a, b)
            if a.task.transient ~= b.task.transient then return a.task.transient == true end
            local ar, br = priorityRank(a.task.priority), priorityRank(b.task.priority)
            if ar ~= br then return ar < br end
            local ad, bd = a.task.due or "9999-99-99", b.task.due or "9999-99-99"
            if ad ~= bd then return ad < bd end
            return a.sourceIndex < b.sourceIndex
        end)
    elseif sortIndex == 2 then
        table.sort(visible, function(a, b)
            if a.task.transient ~= b.task.transient then return a.task.transient == true end
            local ad, bd = a.task.due or "9999-99-99", b.task.due or "9999-99-99"
            if ad ~= bd then return ad < bd end
            local ar, br = priorityRank(a.task.priority), priorityRank(b.task.priority)
            if ar ~= br then return ar < br end
            return a.sourceIndex < b.sourceIndex
        end)
    end
    return visible
end

local function openCount()
    local count = 0
    for _, task in ipairs(tasks) do
        if not task.completed then count += 1 end
    end
    return count
end

local function ensureSelection(visible)
    if #visible == 0 then
        selectedId = nil
        return
    end
    if selectedId ~= nil then
        for _, row in ipairs(visible) do
            if row.task.id == selectedId then return end
        end
    end
    selectedId = visible[1].task.id
end

local function currentTask()
    if selectedId == nil then return nil end
    return findTask(selectedId)
end

local function rebuildTags()
    local seen = {}
    local values = { "" }
    for _, task in ipairs(tasks) do
        for _, project in ipairs(task.projects) do
            local value = "+" .. project
            if not seen[value] then seen[value] = true; values[#values + 1] = value end
        end
    end
    table.sort(values, function(a, b)
        if a == "" then return true end
        if b == "" then return false end
        return a < b
    end)
    tagValues = values
    local present = tagFilter == ""
    for _, value in ipairs(tagValues) do
        if value == tagFilter then present = true end
    end
    if not present then tagFilter = "" end
end

local function tagOptions()
    local result = { tr("all_tags") }
    for index = 2, #tagValues do result[index] = tagValues[index] end
    return result
end

local function tagSelectedIndex()
    for index, value in ipairs(tagValues) do
        if value == tagFilter then return index - 1 end
    end
    return 0
end

local function statusOptions()
    local result = {}
    for i, key in ipairs(STATUS_OPTIONS) do result[i] = tr(key) end
    return result
end

local function priorityOptions()
    return { tr(PRIORITY_OPTIONS[1]), "A", "B", "C", tr(PRIORITY_OPTIONS[5]) }
end

local function sortOptions()
    local result = {}
    for i, key in ipairs(SORT_OPTIONS) do result[i] = tr(key) end
    return result
end

local function replaceTask(task, raw)
    if remote.enabled and (remote.busy or pendingRemote) then return end
    local _, index = findTask(task.id)
    if index == nil then return false end
    parseAt(index, raw, task.id)
    rebuildTags()
    return saveTasks()
end

local function toggleTask(task)
    replaceTask(task, model.setCompleted(task, not task.completed))
end

local function cyclePriority(task)
    local nextPriority = nil
    if task.priority == nil then nextPriority = "A"
    elseif task.priority == "A" then nextPriority = "B"
    elseif task.priority == "B" then nextPriority = "C"
    end
    replaceTask(task, model.setPriority(task, nextPriority))
end

local function removeTask(id)
    if remote.enabled and (remote.busy or pendingRemote) then return end
    local _, index = findTask(id)
    if index == nil then return end
    table.remove(tasks, index)
    deleteId = nil
    selectedId = nil
    rebuildTags()
    saveTasks()
end

local function moveTask(id, beforeId)
    if remote.enabled and (remote.busy or pendingRemote) then return end
    local task, from = findTask(id)
    if task == nil then return end
    local before = beforeId ~= nil and select(2, findTask(beforeId)) or (#tasks + 1)
    if before == nil or before == from or before == from + 1 then return end
    table.remove(tasks, from)
    if from < before then before -= 1 end
    table.insert(tasks, math.max(1, math.min(before, #tasks + 1)), task)
    saveTasks()
end

local function moveSelected(offset)
    if remote.enabled and (remote.busy or pendingRemote) then return end
    if sortIndex ~= 0 or selectedId == nil then return end
    local task, index = findTask(selectedId)
    if task == nil then return end
    local destination = math.max(1, math.min(#tasks, index + offset))
    if destination == index then return end
    table.remove(tasks, index)
    table.insert(tasks, destination, task)
    saveTasks()
end

local function taskCard(task)
    local confirmingDelete = deleteId == task.id
    local selected = selectedId == task.id
    local function editableCell(field, text, width, placeholder, grow, fontSize)
        if editingId == task.id and editingField == field then
            local props = {
                key = "edit-" .. field .. "-" .. task.id,
                value = editDraft,
                placeholder = placeholder,
                focus = true,
                submitOnEnter = true,
                onChange = function(value) editDraft = value end,
                onSubmit = function(value) onEditSave(value) end,
            }
            if field == "title" then props.minHeight = 34 else props.height = 24 end
            if grow then props.flexGrow = 1 else props.width = width end
            return ui.input(props)
        end
        local props = {
            key = "cell-" .. field .. "-" .. task.id,
            align = "center",
            fill = field == "category" and text ~= "" and "secondary/0.22" or nil,
            radius = field == "category" and 8 or 0,
            opacity = task.completed and 0.58 or 1,
            onClick = function() onEdit(task.id, field) end,
        }
        if field == "title" then props.minHeight = 34 else props.height = 24 end
        if grow then props.flexGrow = 1 else props.width = width end
        return ui.row(props, {
            ui.label({
                text = field == "title" and shorten(text, 100) or text,
                maxWidth = grow and nil or width,
                maxLines = 1,
                fontSize = fontSize or (field == "title" and 14 or 11),
                fontWeight = "normal",
                color = "on_surface",
            }),
        })
    end

    local dateField = task.due ~= nil and "due" or "created"
    local date = task.due or task.creationDate or ""
    local mainWidth = MAIN_WIDTH
    local main = editableCell("title", task.title, mainWidth, tr("column_task"), false, 14)
    local actions = ui.row({ width = ACTIONS_WIDTH, gap = 0, align = "center" }, {
        ui.button({ glyph = "pencil", glyphSize = 16, variant = "ghost", width = ACTION_WIDTH, height = 34, tooltip = tr("tip_edit"), onClick = function() onEdit(task.id) end, onRightClick = function() onTaskMenu(task.id) end }),
        ui.button({ glyph = "copy", glyphSize = 16, variant = "ghost", width = ACTION_WIDTH, height = 34, tooltip = tr("tip_copy"), onClick = function() onCopy(task.id) end }),
        ui.button({
            glyph = confirmingDelete and (deleteChoice == 1 and "check" or "x") or "trash",
            glyphSize = 16,
            variant = confirmingDelete and deleteChoice == 1 and "destructive" or "ghost",
            width = ACTION_WIDTH,
            height = 34,
            tooltip = tr(confirmingDelete and (deleteChoice == 1 and "confirm_delete" or "cancel") or "tip_delete"),
            onClick = function()
                if confirmingDelete then
                    if deleteChoice == 1 then onDeleteConfirm() else onDeleteCancel() end
                else
                    onDelete(task.id)
                end
            end,
        }),
    })

    local children = {
        ui.box({
            key = "priority-" .. task.id .. "-" .. tostring(task.priority),
            width = PRIORITY_WIDTH,
            height = 14,
            radius = 7,
            fill = task.priority == "A" and "error" or (task.priority == "B" and "warning" or (task.priority == "C" and "tertiary" or "on_surface_variant")),
            onClick = function() selectedId = task.id; cyclePriority(task); render() end,
        }),
        ui.button({
            glyph = task.completed and "square-check-filled" or "square",
            variant = "ghost",
            width = DONE_WIDTH,
            height = 34,
            glyphSize = 16,
            tooltip = tr(task.completed and "tip_reopen" or "tip_complete"),
            onClick = function() selectedId = task.id; toggleTask(task); render() end,
        }),
        main,
        editableCell(dateField, date, DATE_WIDTH, "2026-09-12", false, 14),
        actions,
        ui.spacer({ width = TRAILING_SPACE }),
    }

    table.insert(children, 1, ui.dragSource({
        key = "grip-" .. task.id,
        dragType = DRAG_TYPE,
        payload = tostring(task.id),
        previewAncestor = 1,
        liftFromLayout = true,
        width = GRIP_WIDTH,
        height = 34,
        align = "center",
        justify = "center",
    }, { ui.glyph({ name = "arrows-move-vertical", size = 16, color = "on_surface_variant" }) }))

    local card = ui.row({
        key = "task-" .. task.id .. (selected and "-selected" or ""),
        gap = ROW_GAP,
        align = "center",
        padding = CARD_PADDING,
        fill = selected and "primary/0.12" or "surface/0.28",
        radius = 10,
        border = selected and "primary/0.45" or "on_surface_variant/0.15",
        borderWidth = CARD_BORDER,
        width = ROW_CONTENT_WIDTH,
        onClick = function() selectedId = task.id; render() end,
    }, children)

    return card
end

local function insertionZone(beforeId, key)
    return ui.dropZone({
        key = "drop-" .. key,
        accepts = { DRAG_TYPE },
        value = beforeId ~= nil and tostring(beforeId) or "end",
        onDrop = "onTaskDrop",
        height = 2,
        radius = 4,
        expandOnDrag = true,
        hitSlop = 20,
    })
end

local function addComposer()
    if not adding then return nil end
    local composer = ui.row({ key = "add-composer", gap = 4, padding = 4, align = "center", fill = "primary/0.10", radius = 8, flexGrow = 1 }, {
        ui.input({
            key = "add-input",
            value = addDraft,
            placeholder = tr("add_placeholder"),
            focus = true,
            controlSize = "sm",
            submitOnEnter = true,
            onChange = function(value) addDraft = value end,
            onSubmit = function(value) onAddSave(value) end,
            flexGrow = 1,
        }),
        ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = tr("cancel"), onClick = "onAddCancel" }),
        ui.button({ text = tr("add"), glyph = "plus", variant = "primary", controlSize = "sm", onClick = "onAddSave" }),
    })
    return ui.row({ key = "add-wrap", paddingH = 10 }, { composer })
end

local function header()
    local left = ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "list-check", size = 20, color = "primary" }),
        ui.label({ text = tr("title"), fontSize = 17, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = tr("subtitle", { shown = #visibleTasks(), open = openCount() }), fontSize = 11, color = "on_surface_variant" }),
    })
    local actions = ui.row({ gap = 3, align = "center" }, {
        ui.button({ glyph = "plus", glyphSize = 14, width = 28, height = 28, variant = "primary", tooltip = tr("tip_add"), onClick = "onAdd" }),
        ui.button({ glyph = "trash-check", glyphSize = 14, width = 28, height = 28, variant = "ghost", tooltip = tr("clear_done"), enabled = openCount() < #tasks, onClick = "onClearDone" }),
        ui.button({ glyph = "keyboard", glyphSize = 14, width = 28, height = 28, variant = "ghost", tooltip = tr("tip_help"), selected = showHelp, onClick = "onHelp" }),
        ui.button({ glyph = "settings", glyphSize = 14, width = 28, height = 28, variant = "ghost", tooltip = tr("tip_settings"), onClick = "onSettings" }),
        ui.button({ glyph = "close", glyphSize = 14, width = 28, height = 28, variant = "ghost", tooltip = tr("tip_close"), onClick = "onCloseClicked" }),
    })
    return ui.column({ gap = 6 }, {
        ui.row({ align = "center", justify = "space_between" }, { left, actions }),
        ui.row({ gap = 6, align = "center" }, {
            ui.input({
                key = "search-" .. searchRev,
                value = query,
                placeholder = tr("search"),
                focus = focusSearch,
                height = 30,
                fontSize = 13,
                flexGrow = 1,
                onChange = function(value) query = value; selectedId = nil; render() end,
            }),
            ui.button({
                key = "status-toggle-" .. statusIndex,
                glyph = STATUS_GLYPHS[statusIndex + 1],
                glyphSize = 14,
                width = 30,
                height = 30,
                variant = "ghost",
                selected = statusIndex ~= 0,
                tooltip = statusOptions()[statusIndex + 1],
                onClick = "onStatusToggle",
            }),
            ui.select({ options = priorityOptions(), selectedIndex = priorityIndex, height = 30, width = 72, onChange = "onPriority" }),
            ui.select({ options = tagOptions(), selectedIndex = tagSelectedIndex(), height = 30, flexGrow = 1, onChange = "onTag" }),
            ui.button({
                key = "sort-toggle-" .. sortIndex,
                glyph = SORT_GLYPHS[sortIndex + 1],
                glyphSize = 14,
                width = 30,
                height = 30,
                variant = "ghost",
                selected = sortIndex ~= 0,
                tooltip = sortOptions()[sortIndex + 1],
                onClick = "onSortToggle",
            }),
        }),
    })
end

function render()
    rebuildTags()
    local visible = visibleTasks()
    ensureSelection(visible)
    local body = {}
    if #visible == 0 then
        body[1] = ui.column({ flexGrow = 1, gap = 8, align = "center", justify = "center" }, {
            ui.glyph({ name = "clipboard-check", size = 38, color = "on_surface_variant" }),
            ui.label({ text = tr("empty"), fontSize = 16, fontWeight = "bold", color = "on_surface" }),
            ui.label({ text = tr("empty_hint"), color = "on_surface_variant" }),
        })
    else
        local rows = {}
        for _, row in ipairs(visible) do
            if sortIndex == 0 then rows[#rows + 1] = insertionZone(row.task.id, tostring(row.task.id)) end
            rows[#rows + 1] = taskCard(row.task)
        end
        if sortIndex == 0 then rows[#rows + 1] = insertionZone(nil, "end") end
        body[1] = ui.scroll({ flexGrow = 1, gap = 4, paddingH = SCROLL_PADDING, align = "stretch" }, rows)
    end

    local parts = { header() }
    if remote.enabled and remote.error then
        parts[#parts + 1] = ui.label({ text = remote.error, color = "error", maxLines = 2 })
    end
    if showHelp then
        parts[#parts + 1] = ui.row({ gap = 8, align = "center", padding = 8, fill = "secondary/0.12", radius = 10 }, {
            ui.glyph({ name = "keyboard", size = 16, color = "secondary" }),
            ui.label({ text = tr("help_body"), fontSize = 11, color = "on_surface", flexGrow = 1, maxLines = 2 }),
        })
    end
    if confirmingClear then
        parts[#parts + 1] = ui.row({ gap = 8, align = "center", padding = 8, fill = "error/0.10", radius = 10 }, {
            ui.label({ text = tr("confirm_clear"), color = "on_surface", flexGrow = 1 }),
            ui.button({ text = tr("cancel"), variant = "ghost", controlSize = "sm", onClick = "onClearCancel" }),
            ui.button({ text = tr("delete"), variant = "destructive", controlSize = "sm", onClick = "onClearConfirm" }),
        })
    end
    parts[#parts + 1] = body[1]
    panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, parts))
    focusSearch = false
end

function onOpen(context)
    opened = true
    remote = noctalia.state.get("todotxt.remote") or {}
    todoPath = model.defaultPath()
    loadTasks()
    rebuildTags()
    local configuredSort = noctalia.getConfig("default_sort") or "manual"
    sortIndex = configuredSort == "priority" and 1 or (configuredSort == "due" and 2 or 0)
    adding = false
    focusSearch = context == "search"
    searchActive = context == "search"
    searchRev += 1
    addDraft = ""
    editingId = nil
    editingField = nil
    deleteId = nil
    confirmingClear = false
    panel.setWantsSecondTicks(true)
    noctalia.state.set("todotxt.open", true)
    if context == "add" then onAdd() else render() end
end

function onClose()
    opened = false
    noctalia.state.set("todotxt.open", false)
end

function onExit()
    noctalia.state.set("todotxt.open", false)
end

function onConfigChanged()
    todoPath = model.defaultPath()
    loadTasks()
    render()
end

function update()
    if remote.enabled then
        if not pendingRemote and editingId == nil and not adding and remoteRevision ~= remote.revision then
            loadTasks()
            rebuildTags()
            render()
        end
        return
    end
    local currentStamp = model.stamp(todoPath)
    if currentStamp ~= diskStamp and not adding and editingId == nil then
        loadTasks()
        rebuildTags()
        render()
    end
end

function onAdd()
    if remote.enabled and (remote.busy or pendingRemote) then return end
    local current = findTask(editingId)
    if current ~= nil and current.transient then
        render()
        return
    end
    local task = {
        id = nextId,
        raw = "",
        completed = false,
        completionDate = nil,
        creationDate = model.today(),
        priority = nil,
        title = "",
        search = "",
        projects = {},
        contexts = {},
        due = nil,
        threshold = nil,
        transient = true,
    }
    nextId += 1
    table.insert(tasks, 1, task)
    selectedId = task.id
    editingId = task.id
    editingField = "title"
    editDraft = ""
    adding = false
    deleteId = nil
    render()
end

function onAddCancel()
    adding = false
    addDraft = ""
    render()
end

function onAddSave(value)
    onEditSave(value)
end

function onEdit(id, field)
    if remote.enabled and (remote.busy or pendingRemote) then return end
    local task = findTask(tonumber(id) or id)
    if task == nil then return end
    selectedId = task.id
    editingId = task.id
    editingField = field or "title"
    if editingField == "category" then
        editDraft = task.projects[1] or ""
    elseif editingField == "context" then
        editDraft = task.contexts[1] or ""
    elseif editingField == "created" then
        editDraft = task.creationDate or ""
    elseif editingField == "due" then
        editDraft = task.due or ""
    else
        editDraft = task.title
    end
    adding = false
    deleteId = nil
    render()
end

function onEditCancel()
    local task, index = findTask(editingId)
    if task ~= nil and task.transient then table.remove(tasks, index) end
    editingId = nil
    editingField = nil
    editDraft = ""
    render()
end

function onEditSave(value)
    if remote.enabled and (remote.busy or pendingRemote) then return end
    local task, index = findTask(editingId)
    if task == nil then return end
    local field = editingField
    local input = trim(type(value) == "string" and value or editDraft)
    if field == "title" and input == "" then
        if task.transient then
            table.remove(tasks, index)
            editingId = nil
            editingField = nil
            editDraft = ""
            render()
        end
        return
    end
    if field == "due" or field == "created" then
        input = input:gsub("^due:", "")
        if input ~= "" and not model.isDate(input) then
            noctalia.notifyError(tr("title"), tr("invalid_date"))
            return
        end
    end
    if field == "title" then
        input = input:gsub("\r\n", "\\n"):gsub("[\r\n]", "\\n")
    end
    local raw = task.raw
    if task.transient and field == "title" then
        raw = model.newLine(input, noctalia.getConfig("add_creation_date") ~= false)
        tasks[index] = model.parse(raw, task.id)
        task = tasks[index]
    elseif field == "title" then raw = model.setTitle(task, input)
    elseif field == "category" then raw = model.setProject(task, input)
    elseif field == "context" then raw = model.setContext(task, input)
    elseif field == "created" then raw = model.setCreationDate(task, input)
    elseif field == "due" then raw = model.setDue(task, input) end
    if not task.transient then replaceTask(task, raw) end
    editingId = nil
    editingField = nil
    editDraft = ""
    render()
end

function onCopy(id)
    local task = findTask(tonumber(id) or id)
    if task == nil then return end
    selectedId = task.id
    local full = task.title or ""
    if full ~= "" then
        full = full:gsub("\\n", "\n")
        noctalia.copyToClipboard(full, "text/plain;charset=utf-8")
        noctalia.notify(tr("title"), tr("copied"))
    end
    render()
end

function onDelete(id)
    local task = findTask(tonumber(id) or id)
    if task == nil then return end
    if task.transient then
        local _, index = findTask(task.id)
        table.remove(tasks, index)
        editingId = nil
        editingField = nil
        render()
        return
    end
    selectedId = task.id
    deleteId = task.id
    deleteChoice = 1
    editingId = nil
    editingField = nil
    render()
end

function onDeleteCancel()
    deleteId = nil
    render()
end

function onDeleteConfirm()
    if deleteId ~= nil then removeTask(deleteId) end
    render()
end

function onClearDone()
    confirmingClear = true
    render()
end

function onClearCancel()
    confirmingClear = false
    render()
end

function onClearConfirm()
    if remote.enabled and (remote.busy or pendingRemote) then return end
    local kept = {}
    for _, task in ipairs(tasks) do
        if not task.completed then kept[#kept + 1] = task end
    end
    tasks = kept
    confirmingClear = false
    selectedId = nil
    rebuildTags()
    saveTasks()
    render()
end

function onSearch()
    searchActive = not searchActive
    focusSearch = searchActive
    searchRev += 1
    render()
end

function onHelp()
    showHelp = not showHelp
    render()
end

function onSettings()
    panel.close()
    noctalia.openSettings()
end

function onCloseClicked()
    panel.close()
end

function onStatus(index)
    statusIndex = math.max(0, math.min(2, tonumber(index) or 0))
    selectedId = nil
    render()
end

function onStatusToggle()
    statusIndex = (statusIndex + 1) % #STATUS_OPTIONS
    selectedId = nil
    render()
end

function onPriority(index)
    priorityIndex = math.max(0, math.min(4, tonumber(index) or 0))
    selectedId = nil
    render()
end

function onTag(index)
    tagFilter = tagValues[(tonumber(index) or 0) + 1] or ""
    selectedId = nil
    render()
end

function onSort(index)
    sortIndex = math.max(0, math.min(2, tonumber(index) or 0))
    selectedId = nil
    render()
end

function onSortToggle()
    sortIndex = (sortIndex + 1) % #SORT_OPTIONS
    selectedId = nil
    render()
end

function onTaskMenu(id)
    local task = findTask(tonumber(id) or id)
    if task == nil then return end
    panel.openContextMenu({
        context = tostring(task.id),
        onActivate = "onTaskMenuAction",
        items = {
            { kind = "header", label = task.title },
            { id = "toggle", label = tr(task.completed and "tip_reopen" or "tip_complete") },
            { id = "edit", label = tr("tip_edit") },
            { id = "copy", label = tr("tip_copy") },
            { kind = "separator" },
            { id = "priority", label = tr("tip_priority") },
            { id = "delete", label = tr("tip_delete") },
        },
    })
end

function onTaskMenuAction(action, context)
    local task = findTask(tonumber(context))
    if task == nil then return end
    if action == "toggle" then toggleTask(task)
    elseif action == "edit" then onEdit(task.id); return
    elseif action == "copy" then onCopy(task.id); return
    elseif action == "priority" then cyclePriority(task)
    elseif action == "delete" then onDelete(task.id); return
    end
    render()
end

function onKey(chord, pressed)
    if not pressed then return end
    if chord == "n" or chord == "ctrl+n" then onAdd(); return end
    if chord == "ctrl+h" then onHelp(); return end
    if adding or editingId ~= nil then return end
    if chord == "ctrl+f" then onSearch(); return end

    if deleteId ~= nil then
        if chord == "left" then
            deleteChoice = 0
        elseif chord == "right" then
            deleteChoice = 1
        elseif chord == "d" or chord == "delete" then
            if deleteChoice == 1 then onDeleteConfirm() else onDeleteCancel() end
            return
        end
        render()
        return
    end

    local visible = visibleTasks()
    ensureSelection(visible)
    if #visible == 0 then return end
    local current = 1
    for index, row in ipairs(visible) do
        if row.task.id == selectedId then current = index; break end
    end

    if chord == "j" or chord == "down" then
        selectedId = visible[current % #visible + 1].task.id
    elseif chord == "k" or chord == "up" then
        selectedId = visible[(current - 2) % #visible + 1].task.id
    elseif chord == "home" then
        selectedId = visible[1].task.id
    elseif chord == "end" then
        selectedId = visible[#visible].task.id
    elseif chord == "x" then
        local task = currentTask(); if task ~= nil then toggleTask(task) end
    elseif chord == "e" then
        local task = currentTask(); if task ~= nil then onEdit(task.id); return end
    elseif chord == "c" or chord == "y" then
        local task = currentTask(); if task ~= nil then onCopy(task.id); return end
    elseif chord == "d" or chord == "delete" then
        onDelete(selectedId)
        return
    elseif chord == "shift+up" then
        moveSelected(-1)
    elseif chord == "shift+down" then
        moveSelected(1)
    end
    render()
end

noctalia.state.watch("todotxt.remote", function(value)
    local wasRemote = remote.enabled == true
    remote = value or {}
    if pendingRemote and remote.request == pendingRemote and not remote.busy then
        pendingRemote = nil
        if remote.success then noctalia.removeFile(noctalia.pluginDataDir() .. "/caldav-unsaved.txt")
        else noctalia.notifyError(tr("title"), remote.error or tr("remote_unavailable")) end
        loadTasks()
    elseif wasRemote ~= (remote.enabled == true) then
        editingId = nil
        loadTasks()
    end
    if opened then render() end
end)
