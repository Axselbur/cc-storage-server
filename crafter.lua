--[[
  ================================================================
  CC Storage Server -- crafter.lua (черепашка с верстаком)
  ================================================================
  Забирает заказы на крафт с сервера и выполняет их:

    * рецепты верстака (turtle.craft) прогонами по вместимости:
      сетка крафта = слоты 1,2,3 / 5,6,7 / 9,10,11, остальные слоты
      обязаны быть пустыми;
    * рецепты механизмов (пользовательские): ингредиенты в механизм
      по сети, ожидание результата в выходном инвентаре.

  ТРЕБОВАНИЯ:
    - черепашка стоит рядом с верстаком И подключена к вольтам
      проводной сетью (wired modem) -- без него pushItems не работает;
    - http включён в CC-конфиге;
    - адрес сервера ПУБЛИЧНЫЙ (https://...onrender.com).

  УСТАНОВКА:
    wget https://<app>.onrender.com/crafter.lua startup ; reboot
  ================================================================
]]

-- ======================= SETTINGS =======================
local CONFIG = {
    server_url = "https://cc-storage-server.onrender.com",
    device_key = "-77QIbhF2zXqjZgrhWeozH_ycB8pnTf2",

    poll_interval = 15,     -- как часто проверять заказы, с
    fallback_storage = {},  -- вольты, если сервер не отдал конфиг
    fallback_turtle_name = "",

    use_monitor = true,
    monitor_text_scale = 0.5,

    -- Раскладка сетки крафта в инвентаре черепашки:
    -- "corner" -- угол 4x4-инвентаря: 1,2,3 / 5,6,7 / 9,10,11
    -- "linear" -- слоты 1-9 подряд (старые версии CC)
    -- Это лишь порядок попытки: если крафт не прошёл, черепашка сама
    -- переложит предметы в другую раскладку и попробует снова.
    grid_mode = "corner",
}
-- ========================================================

if not turtle then
    printError("This program must run on a TURTLE.")
    return
end
if not turtle.craft then
    printError("The turtle needs a CRAFTING TABLE attached!")
    return
end
if not http then
    printError("HTTP API is not available! Enable http in the CC config.")
    return
end

-- ======================= HTTP =======================
local function api_get(path)
    local ok, response = pcall(http.get, CONFIG.server_url .. path,
        { ["X-Device-Key"] = CONFIG.device_key })
    if ok and response then
        local body = response.readAll()
        response.close()
        if body then
            local ok2, data = pcall(textutils.unserializeJSON, body)
            if ok2 then
                return data
            end
        end
    end
    return nil
end

local function api_post(path, payload)
    local ok_json, body = pcall(textutils.serializeJSON, payload)
    if not ok_json then
        return false
    end
    local ok, response = pcall(http.post, CONFIG.server_url .. path, body, {
        ["Content-Type"] = "application/json",
        ["X-Device-Key"] = CONFIG.device_key,
    })
    if ok and response then
        response.close()
        return true
    end
    return false
end

local function heartbeat()
    return api_post("/api/heartbeat", { computer = os.computerID() })
end

-- ======================= КОНФИГ С СЕРВЕРА =======================
local SERVER_CONFIG = {}

local function fetch_server_config()
    local cfg = api_get("/api/config")
    if type(cfg) == "table" then
        SERVER_CONFIG = cfg
        return true
    end
    return false
end

-- ======================= ПЕРИФЕРИЯ =======================
-- Черепашка работает ТОЛЬКО с вольтами из конфига сайта: чужие
-- хранилища (буфер станка и т.п.) не трогаем.
local function cfg_vaults()
    local v = SERVER_CONFIG.vaults
    if type(v) == "table" and #v > 0 then return v end
    return CONFIG.fallback_storage or {}
end

local function normalize_name(s)
    return string.lower(string.gsub(s, "[:%s_%-]", ""))
end

local function resolve_name(want)
    local names = peripheral.getNames()
    for _, n in ipairs(names) do
        if n == want then return n end
    end
    local w = normalize_name(want)
    for _, n in ipairs(names) do
        if normalize_name(n) == w then return n end
    end
    local num = string.match(want, "(%d+)$")
    if num then
        for _, n in ipairs(names) do
            if string.match(n, "(%d+)$") == num then return n end
        end
    end
    return nil
end

local function get_inventory(name)
    local n = resolve_name(name)
    if not n then return nil end
    local inv = peripheral.wrap(n)
    if inv and inv.list then return inv end
    return nil
end

local function scan_vault(inv)
    local out = {}
    local ok, list = pcall(inv.list)
    if not ok then return nil end
    for _, item in pairs(list) do
        out[item.name] = (out[item.name] or 0) + item.count
    end
    return out
end

-- Имя черепашки в проводной сети (нужно, чтобы вольты могли pushItems
-- прямо в её слоты). Табличка с label НЕ меняет сетевое имя.
local function get_turtle_network_name()
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "modem" then
            local m = peripheral.wrap(n)
            local isW = nil
            pcall(function() isW = m.isWireless() end)
            if isW == false or isW == nil then
                local ok, name = pcall(m.getNameLocal)
                if ok and name then return name end
            end
        end
    end
    return nil
end

-- ======================= СОСТОЯНИЕ =======================
local activeVaults = {}
local stock = {}
local turtleName = nil
local configOk = false

local function scan_all_vaults()
    activeVaults = {}
    stock = {}
    for _, name in ipairs(cfg_vaults()) do
        local inv = get_inventory(name)
        if inv then
            local data = scan_vault(inv)
            if data then
                table.insert(activeVaults, name)
                for id, cnt in pairs(data) do
                    stock[id] = (stock[id] or 0) + cnt
                end
            end
        end
    end
    return #activeVaults
end

-- ======================= ПЕРЕКЛАДКА ПРЕДМЕТОВ =======================
local function vault_slot_with(vault, id)
    local ok, list = pcall(vault.list)
    if not ok then return nil end
    for slot, item in pairs(list) do
        if item.name == id then return slot end
    end
    return nil
end

-- Набрать want предметов id в слот toSlot черепашки из любых вольтов.
local function pull_into_slot(id, toSlot, want)
    local cur = turtle.getItemCount(toSlot)
    local attempts = 0
    while cur < want and attempts < 8 do
        attempts = attempts + 1
        local advanced = false
        for _, vname in ipairs(activeVaults) do
            if cur >= want then break end
            local vault = get_inventory(vname)
            if vault then
                local slot = vault_slot_with(vault, id)
                if slot then
                    local ok, m = pcall(vault.pushItems, turtleName, slot, want - cur, toSlot)
                    if ok and m and m > 0 then
                        cur = turtle.getItemCount(toSlot)
                        advanced = true
                    end
                end
            end
        end
        if not advanced then break end
    end
    return cur
end

local function push_slot_out(slot, target)
    local count = turtle.getItemCount(slot)
    if count <= 0 then return true end
    -- основной путь: вольт сам забирает из черепашки
    -- (то же направление, что при выдаче ингредиентов -- оно работает)
    local vault = get_inventory(target)
    if vault then
        local ok, m = pcall(vault.pullItems, turtleName, slot, count)
        if ok and m and m > 0 then
            count = turtle.getItemCount(slot)
        end
    end
    -- запасной путь: толкаем из черепашки
    if count > 0 then
        local ok, m = pcall(turtle.pushItems, target, slot, count)
        if ok and m and m > 0 then
            count = turtle.getItemCount(slot)
        end
    end
    return count <= 0
end

-- Всё из черепашки -> destination (если задан) или в любой вольт.
local function empty_turtle(destination)
    local cleared = true
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local moved = false
            if destination and destination ~= "" then
                moved = push_slot_out(slot, resolve_name(destination) or destination)
            end
            if not moved then
                for _, vname in ipairs(activeVaults) do
                    if push_slot_out(slot, resolve_name(vname) or vname) then
                        moved = true
                        break
                    end
                end
            end
            if not moved then cleared = false end
        end
    end
    return cleared
end

-- Все слоты чужого инвентаря -> destination, затем вольты по очереди.
-- Если задан onlyItem -- двигаем ТОЛЬКО этот предмет (чужие вещи не трогаем).
local function drain_to_vaults(inv, destination, sourceName, onlyItem)
    if not inv then return end
    local ok, list = pcall(inv.list)
    if not ok then return end
    for slot, item in pairs(list) do
        local count = item.count
        if count > 0 and (not onlyItem or item.name == onlyItem) then
            local targets = {}
            if destination and destination ~= "" then
                table.insert(targets, resolve_name(destination) or destination)
            end
            for _, vname in ipairs(activeVaults) do
                local rn = resolve_name(vname) or vname
                local dup = false
                for _, t in ipairs(targets) do
                    if t == rn then dup = true end
                end
                if not dup then table.insert(targets, rn) end
            end
            for _, tname in ipairs(targets) do
                if count <= 0 then break end
                local okp, m = pcall(inv.pushItems, tname, slot, count)
                if okp and m and m > 0 then count = count - m end
                -- запасной путь: вольт сам тянет из этого инвентаря
                if count > 0 and sourceName then
                    local vault = get_inventory(tname)
                    if vault then
                        local ok2, m2 = pcall(vault.pullItems, sourceName, slot, count)
                        if ok2 and m2 and m2 > 0 then count = count - m2 end
                    end
                end
            end
        end
    end
end

local function inventory_total(inv)
    local ok, list = pcall(inv.list)
    if not ok then return 0 end
    local t = 0
    for _, item in pairs(list) do t = t + item.count end
    return t
end

local function count_in_inventory(inv, id)
    local ok, list = pcall(inv.list)
    if not ok then return 0 end
    local t = 0
    for _, item in pairs(list) do
        if item.name == id then t = t + item.count end
    end
    return t
end

local function push_all_turtle_to(target)
    local moved = 0
    local input = get_inventory(target)
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local count = turtle.getItemCount(slot)
            local ok, m = pcall(turtle.pushItems, target, slot, count)
            if ok and m and m > 0 then
                moved = moved + m
                count = turtle.getItemCount(slot)
            end
            -- запасной путь: приёмник сам тянет из черепашки
            if count > 0 and input then
                local ok2, m2 = pcall(input.pullItems, turtleName, slot, count)
                if ok2 and m2 and m2 > 0 then moved = moved + m2 end
            end
        end
    end
    return moved
end

-- ======================= КРАФТ НА ВЕРСТАКЕ =======================
-- Раскладка сетки зависит от версии CC (см. CONFIG.grid_mode), поэтому
-- крафт САМ ПОДБИРАЕТ раскладку: пробует предпочтительную, при неудаче
-- перекладывает предметы в альтернативную и пробует снова.
local GRID_MODES = {
    { slots = { 1, 2, 3, 5, 6, 7, 9, 10, 11 } },  -- corner (CC:Tweaked)
    { slots = { 1, 2, 3, 4, 5, 6, 7, 8, 9 } },     -- linear (старые CC)
}
local gridOrder
if CONFIG.grid_mode == "linear" then
    gridOrder = { 2, 1 }
else
    gridOrder = { 1, 2 }
end

local function relocate_slots(fromSlots, toSlots)
    for i = 1, 9 do
        local from = fromSlots[i]
        local to = toSlots[i]
        if from ~= to then
            local count = turtle.getItemCount(from)
            if count > 0 then
                turtle.select(from)
                turtle.transferTo(to, count)
            end
        end
    end
end

local function craft_step_table(step)
    local remaining = step.batches or 1
    local per_craft = (step.count or 0) / (step.batches or 1)

    -- какие предметы класть в сетку (на 1 крафт).
    -- ВАЖНО: для form-рецептов позиции пустых ячеек сохраняются!
    local cells = {}
    if step.shapeless then
        for _, ing in ipairs(step.ingredients or {}) do
            local per = ing.count / (step.batches or 1)
            for _ = 1, per do
                table.insert(cells, ing.id)
            end
        end
    else
        local grid = step.grid or {}
        for i = 1, 9 do
            cells[i] = grid[i]
        end
    end
    local hasAny = false
    for i = 1, 9 do
        if cells[i] then hasAny = true break end
    end
    if not hasAny then error("empty grid") end

    while remaining > 0 do
        -- 1) черепашка пустая, иначе turtle.craft не пройдёт
        if not empty_turtle(nil) then
            error("turtle not empty (vaults full?)")
        end

        -- 2) сколько крафтов можно сделать за прогон
        local want = math.min(remaining, 64)
        want = math.min(want, math.floor(7 * 64 / per_craft))
        if want < 1 then want = 1 end

        -- 3) набрать предметы в предпочтительную раскладку сетки
        local slotMap = {}
        for i = 1, 9 do
            local gid = cells[i]
            if gid then
                slotMap[i] = pull_into_slot(gid, GRID_MODES[gridOrder[1]].slots[i], want)
            end
        end
        local runs = want
        for _, c in pairs(slotMap) do runs = math.min(runs, c) end
        if runs < 1 then
            error("not enough in storage")
        end

        -- 4) крафт; если раскладка не подошла -- пробуем альтернативную
        local crafted = false
        for k = 1, #gridOrder do
            if k > 1 then
                relocate_slots(GRID_MODES[gridOrder[1]].slots, GRID_MODES[gridOrder[k]].slots)
                print("  layout " .. tostring(gridOrder[1]) .. " failed, trying " .. tostring(gridOrder[k]))
            end
            turtle.select(1)
            if turtle.craft(runs) then
                crafted = true
                if k > 1 then
                    gridOrder = { gridOrder[k], gridOrder[1] }
                    print("  grid layout switched")
                end
                break
            end
        end
        if not crafted then
            -- показать, что лежало в сетке, для диагностики
            local desc = {}
            for i = 1, 9 do
                local gid = cells[i]
                if gid then
                    desc[#desc + 1] = tostring(i) .. ":" .. tostring(gid)
                end
            end
            error("turtle.craft failed (cells: " .. table.concat(desc, " ") .. ")")
        end

        -- 5) результат -> вольты
        empty_turtle(step.destination)
        remaining = remaining - runs
        print("craft: " .. tostring(step.result) .. " " ..
            tostring(step.batches - remaining) .. "/" .. tostring(step.batches))
    end
end

-- ======================= КРАФТ ЧЕРЕЗ МЕХАНИЗМ =======================
local function wait_for_output(output, result, target)
    local lastBeat = 0
    while true do
        local have = count_in_inventory(output, result)
        if have >= target then return end
        local now = os.epoch("utc")
        if now - lastBeat > 30000 then
            heartbeat()
            lastBeat = now
            print("waiting: " .. tostring(result) .. " " .. tostring(have) .. "/" .. tostring(target))
        end
        os.sleep(3)
    end
end

local function count_item(id)
    local total = 0
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name == id then
            total = total + d.count
        end
    end
    return total
end

local function craft_step_mechanism(step)
    local inName = resolve_name(step.mechanism_input) or step.mechanism_input
    local outName = resolve_name(step.mechanism_output) or step.mechanism_output
    local input = peripheral.wrap(inName)
    local output = peripheral.wrap(outName)
    if not input or not output then error("mechanism not found") end

    local result = step.result
    local per_craft = (step.count or 0) / (step.batches or 1)
    local batches = step.batches or 1

    -- чужие вещи не трогаем: убираем из выхода только НАШ результат
    drain_to_vaults(output, step.destination, outName, result)

    local idset = {}
    for _, ing in ipairs(step.ingredients) do idset[ing.id] = true end

    local remaining = batches
    while remaining > 0 do
        -- размер порции: не больше СТАКА (64) на ингредиент на 1 крафт
        -- (на депо больше стака положить нельзя), и чтобы влезало
        -- в 16 слотов черепашки
        local runs = remaining
        local minPerBatch = nil
        for _, ing in ipairs(step.ingredients) do
            local per = ing.count / batches
            if not minPerBatch or per < minPerBatch then minPerBatch = per end
        end
        runs = math.min(runs, math.floor(64 / math.max(1, minPerBatch)))
        while runs > 1 do
            local slots = 0
            for _, ing in ipairs(step.ingredients) do
                slots = slots + math.ceil(ing.count * runs / 64)
            end
            if slots <= 16 then break end
            runs = math.floor(runs / 2)
        end
        if runs < 1 then runs = 1 end

        if not empty_turtle(nil) then
            error("turtle not empty (vaults full?)")
        end

        -- набрать ингредиенты: ing.count -- ВСЕГО за шаг, поэтому на
        -- порцию нужно (ing.count / batches) * runs штук
        local pulled = {}
        for _, ing in ipairs(step.ingredients) do
            local per = ing.count / batches
            local need = math.ceil(per * runs)
            local have = 0
            for slot = 1, 16 do
                if have >= need then break end
                local cur = pull_into_slot(ing.id, slot, need - have)
                if cur and cur > 0 then have = have + cur end
            end
            pulled[ing.id] = have
        end

        -- скормить машине
        push_all_turtle_to(inName)

        -- сколько машина реально приняла (что осталось в черепашке -- не приняла)
        local fed = runs
        for _, ing in ipairs(step.ingredients) do
            local per = ing.count / batches
            local taken = pulled[ing.id] - count_item(ing.id)
            fed = math.min(fed, math.floor(taken / per))
        end
        if fed < 1 then
            empty_turtle(nil)
            error("input won't accept")
        end
        empty_turtle(nil)

        -- ЖДЁМ ПО КОЛИЧЕСТВУ, а не по времени: положили fed крафтов --
        -- значит ждём ровно per_craft*fed результата, и пока его не будет,
        -- НИЧЕГО не забираем. (wait_for_output ждёт бесконечно.)
        wait_for_output(output, result, per_craft * fed)

        -- только теперь: вернуть ингредиенты, которые станок не потребил
        local okL, listL = pcall(input.list)
        if okL and type(listL) == "table" then
            for slot, info in pairs(listL) do
                if type(info) == "table" and idset[info.name] and (info.count or 0) > 0 then
                    local rest = info.count
                    for _, vname in ipairs(activeVaults) do
                        if rest <= 0 then break end
                        local okp, m = pcall(input.pushItems, resolve_name(vname) or vname, slot, rest)
                        if okp and m and m > 0 then rest = rest - m end
                    end
                end
            end
        end

        drain_to_vaults(output, step.destination, outName, result)
        remaining = remaining - fed
        print("mechanism: " .. tostring(result) .. " " ..
            tostring(batches - remaining) .. "/" .. tostring(batches))
    end
end

-- ======================= ИСПОЛНЕНИЕ ЗАКАЗА =======================
local function step_ready(step)
    local ings = step.ingredients
    if not ings or #ings == 0 then
        return true
    end
    for _, ing in ipairs(ings) do
        if ing.id and ing.count and ing.count > 0 then
            local have = (stock[ing.id] or 0) + count_item(ing.id)
            if have < ing.count then
                return false
            end
        end
    end
    return true
end

local function execute_step(step)
    if step.method == "mechanism" then
        craft_step_mechanism(step)
    else
        craft_step_table(step)
    end
end

local function report_progress(order, made)
    api_post("/api/orders/progress", { order = order.id, step = made, status = "ok" })
end

local function report_fail(order, msg)
    api_post("/api/orders/progress", { order = order.id, status = "fail", msg = tostring(msg) })
end

-- Как CraftingCpuLogic.executeCrafting в AE2: проходы по шагам,
-- готовые выполняем, после каждого успеха пересканируем склад.
-- Если заказ уже был начат (step_done > 0) -- продолжаем с места
-- остановки, чтобы не перекрафчивать готовые шаги.
local function process_order(order)
    local steps = order.steps or {}
    if #steps == 0 then
        report_fail(order, "no steps")
        return
    end

    scan_all_vaults()
    local done = {}
    local made = order.step_done or 0
    for i = 1, made do
        done[i] = true
    end
    local lastErr = nil

    while made < #steps do
        local progressed = false
        for i, step in ipairs(steps) do
            if not done[i] and step_ready(step) then
                local ok, err = pcall(execute_step, step)
                if ok then
                    done[i] = true
                    made = made + 1
                    progressed = true
                    scan_all_vaults()
                    report_progress(order, made)
                    if made >= #steps then return end
                else
                    lastErr = err
                end
            end
        end
        if not progressed then
            -- вернуть всё, что накопилось в черепашке, в вольты
            pcall(empty_turtle, nil)
            report_fail(order, lastErr or "no progress")
            return
        end
    end
end

-- ======================= МОНИТОР =======================
-- ЖЁСТКОЕ ПРАВИЛО: монитор только вплотную к черепашке (любой гранью),
-- по сети мониторы не подхватываются.
local DIRECT_SIDES = { top = true, bottom = true, left = true, right = true,
                       front = true, back = true }

local function setup_monitor()
    if not CONFIG.use_monitor then
        return
    end
    local mName = nil
    for _, n in ipairs(peripheral.getNames()) do
        if DIRECT_SIDES[n] and peripheral.getType(n) == "monitor" then
            mName = n
            break
        end
    end
    if not mName then
        print("No monitor attached (touch only, not via network)")
        return
    end
    print("Output -> external monitor (" .. mName .. ")")
    local mon = peripheral.wrap(mName)
    if mon.setTextScale then
        pcall(mon.setTextScale, CONFIG.monitor_text_scale)
    end
    term.redirect(mon)
end

local function draw_screen(line1, line2)
    term.clear()
    term.setCursorPos(1, 1)
    print("== Auto Crafter ==")
    print("Turtle: " .. tostring(turtleName))
    print("Vaults: " .. tostring(#activeVaults))
    print(configOk and "SERVER LINK: OK" or "NO SERVER CONNECTION!")
    if line1 then print(line1) end
    if line2 then print(line2) end
end

-- Экран очереди: ВСЕ заказы с сервера (монитор большой).
-- Строки дополняются пробелами до ширины экрана, чтобы от прошлого
-- кадра не оставалось "хвостов" (артефактов).
local function draw_queue_screen(orders)
    term.clear()
    term.setCursorPos(1, 1)
    local w, h = term.getSize()
    local function wline(s)
        local t = tostring(s or "")
        if #t > w then t = t:sub(1, w) end
        term.write(t .. string.rep(" ", w - #t))
        print("")
    end

    wline("== Auto Crafter ==")
    wline("Turtle: " .. tostring(turtleName))
    wline("Vaults: " .. tostring(#activeVaults))
    wline(configOk and "SERVER LINK: OK" or "NO SERVER CONNECTION!")
    wline("Queue:")

    if not orders or #orders == 0 then
        wline("  (пусто)")
        return
    end
    for i = 1, #orders do
        local o = orders[i]
        if type(o) == "table" then
            local item = tostring(o.item or "?")
            local name = string.match(item, ":([^:]+)$") or item
            if #name > 16 then name = name:sub(1, 16) end
            local cnt = tonumber(o.count) or 0
            local st = tostring(o.status or "")
            local mark = "?"
            if st == "queued" then mark = "[Q]"
            elseif st == "crafting" then mark = "[C]"
            elseif st == "done" then mark = "[OK]"
            elseif st == "failed" then mark = "[X]"
            elseif st == "missing" then mark = "[!]" end
            wline(" " .. mark .. " " .. name .. " x" .. tostring(cnt))
        end
    end
end

-- ======================= ГЛАВНЫЙ ЦИКЛ =======================
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("CC Storage Server: auto crafter")
    print("Server: " .. CONFIG.server_url)
    setup_monitor()
    turtleName = get_turtle_network_name()

    local iter = 0
    while true do
        iter = iter + 1

        if iter % 4 == 1 then
            configOk = fetch_server_config()
            if not turtleName then
                turtleName = SERVER_CONFIG.turtle_name
            end
        end

        -- heartbeat всегда, чтобы сайт видел черепашку на связи
        heartbeat()

        if scan_all_vaults() == 0 then
            draw_screen("NO VAULT REACHABLE", "add vaults in config or check wired network")
            os.sleep(5)
        else
            local data = api_get("/api/orders/next")
            local order = data and data.order
            if order then
                draw_screen("Order #" .. tostring(order.id) .. ": " .. tostring(order.item))
                pcall(process_order, order)
            else
                local ordData = api_get("/api/orders")
                draw_queue_screen(ordData and ordData.orders or nil)
                os.sleep(CONFIG.poll_interval)
            end
        end
    end
end

local ok, err = pcall(main)
if not ok then
    term.redirect(term.native())
    printError("Error: " .. tostring(err))
end
