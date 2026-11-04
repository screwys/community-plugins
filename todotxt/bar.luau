--!nonstrict

local model = require("./model.luau")

local tasks = {}
local remote = noctalia.state.get("todotxt.remote") or {}
local reading = false
local panelOpen = false

local function priorityRank(priority)
    if priority == "A" then return 1 end
    if priority == "B" then return 2 end
    if priority == "C" then return 3 end
    return 4
end

local function openTasks()
    local result = {}
    for index, task in ipairs(tasks) do
        if not task.completed and (task.threshold == nil or task.threshold <= model.today()) then
            result[#result + 1] = { task = task, index = index }
        end
    end
    table.sort(result, function(a, b)
        local ad, bd = a.task.due or "9999-99-99", b.task.due or "9999-99-99"
        if ad ~= bd then return ad < bd end
        local ar, br = priorityRank(a.task.priority), priorityRank(b.task.priority)
        if ar ~= br then return ar < br end
        return a.index < b.index
    end)
    return result
end

local function shorten(text, limit)
    if text == nil or text == "" then return "" end
    local display = text:gsub("\\n", " "):gsub("[\r\n]+", " ")
    local length = utf8.len(display)
    if length == nil or length <= limit then return display end
    local finish = utf8.offset(display, limit + 1)
    if finish == nil then return display end
    return display:sub(1, finish - 1) .. "…"
end

local function priorityColor(priority)
    if priority == "A" then return "error" end
    if priority == "B" then return "warning" end
    if priority == "C" then return "tertiary" end
    return "on_surface_variant"
end

local function isVerticalLayout()
    return barWidget.isVertical()
end

local function render()
    local open = openTasks()
    local count = #open
    local first = count > 0 and open[1].task or nil
    local hide = noctalia.getConfig("hide_when_empty") == true and count == 0
    barWidget.setVisible(not hide)
    if hide then return end

    local glyph = noctalia.getConfig("glyph") or "list-check"
    local display = noctalia.getConfig("display") or "count"
    local vertical = isVerticalLayout()
    if vertical and display == "next" then display = "count" end
    local compactCount = display == "count"
    local container = compactCount and ui.column or (vertical and ui.column or ui.row)
    local icon = ui.glyph({ name = glyph, size = 18, color = panelOpen and "primary" or "on_surface" })
    local children = {}
    children[1] = icon
    if display == "count" then
        children[2] = ui.label({ text = tostring(count), fontSize = vertical and 9 or 11, fontWeight = "bold", color = panelOpen and "primary" or "on_surface", baseline = "inkCentered", maxLines = 1 })
    elseif display == "next" then
        if first == nil then
            children[#children + 1] = ui.label({
                text = tostring(count),
                color = count == 0 and "on_surface_variant" or "on_surface",
                fontWeight = "bold",
                maxLines = 1,
            })
        else
            children[#children + 1] = ui.box({
                width = 8,
                height = 8,
                radius = 4,
                fill = priorityColor(first.priority),
            })
            children[#children + 1] = ui.label({
                text = shorten(first.title, tonumber(noctalia.getConfig("max_title_length")) or 28),
                color = "on_surface",
                fontWeight = "medium",
                maxLines = 1,
            })
            if noctalia.getConfig("show_due") ~= false and first.due ~= nil then
                children[#children + 1] = ui.glyph({ name = "calendar", size = 13, color = first.due < model.today() and "error" or "on_surface_variant" })
                children[#children + 1] = ui.label({ text = first.due, color = first.due < model.today() and "error" or "on_surface_variant", maxLines = 1 })
            end
        end
    end

    barWidget.render(container({ gap = compactCount and (vertical and 1 or 4) or (vertical and 3 or 6), align = "center" }, children))
    if first == nil then
        barWidget.setTooltip(noctalia.tr("widget_empty"))
    else
        barWidget.setTooltip(noctalia.tr("widget_tooltip", { count = count, next = (first.raw or ""):gsub("\\n", "\n") }))
    end
end

local function refresh()
    if remote.enabled then
        tasks = {}
        for _, row in ipairs(remote.tasks or {}) do tasks[#tasks + 1] = model.parse(row.raw, row.id, true) end
        render()
        return
    end
    if reading then return end
    reading = true
    local accepted = noctalia.readFileAsync(model.defaultPath(), function(data, _err)
        reading = false
        if not remote.enabled then tasks = model.readText(data, true); render() end
    end)
    if not accepted then reading = false end
end

noctalia.state.watch("todotxt.open", function(value)
    panelOpen = value == true
    render()
end)

noctalia.state.watch("todotxt.changed", function(_value)
    refresh()
end)

function update()
    refresh()
end

function onConfigChanged()
    refresh()
    render()
end

noctalia.state.watch("todotxt.remote", function(value)
    remote = value or {}
    refresh()
end)

noctalia.setUpdateInterval(2000)
refresh()
render()
