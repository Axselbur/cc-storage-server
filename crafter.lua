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
}
-- ========================================================

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
-- Принимаем любые варианты имён вольтов/силосов:
-- create:item_vault_1, create_connected:item_silo_75 и т.п.
local function is_vault_name(n)
    local norm = string.lower(string.gsub(n, "[:%s_%-]", ""))
    if string.match(norm, "(%d+)$") == nil then
        return false
    end
    return string.match(norm, "itemvault") ~= nil
        or string.match(norm, "itemsilo") ~= nil
end

local function discover_vaults()
    local out = {}
    for _, n in ipairs(peripheral.getNames()) do
        if is_vault_name(n) then
            table.insert(out, n)
        end
    end
    table.sort(out)
    return out
end

local function cfg_vaults()
    local v = SERVER_CONFIG.vaults
    if type(v) == "table" and #v > 0 then return v end
    v = CONFIG.fallback_storage or {}
    if #v > 0 then return v end
    return discover_vaults()
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
    local ok, m = pcall(turtle.pushItems, target, slot, count)
    if not ok then return false end
    return turtle.getItemCount(slot) == 0
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
local function drain_to_vaults(inv, destination)
    if not inv then return end
    local ok, list = pcall(inv.list)
    if not ok then return end
    for slot, item in pairs(list) do
        local count = item.count
        if count > 0 then
            if destination and destination ~= "" then
                local okp, m = pcall(inv.pushItems, resolve_name(destination) or destination, slot, count)
                if okp and m and m > 0 then count = count - m end
            end
            for _, vname in ipairs(activeVaults) do
                if count <= 0 then break end
                local okp, m = pcall(inv.pushItems, resolve_name(vname) or vname, slot, count)
                if okp and m and m > 0 then count = count - m end
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
    for slot = 1, 16 do
        if turtle.getItemCount(slot) > 0 then
            local ok, m = pcall(turtle.pushItems, target, slot, turtle.getItemCount(slot))
            if ok and m and m > 0 then moved = moved + m end
        end
    end
    return moved
end

-- ======================= КРАФТ НА ВЕРСТАКЕ =======================
-- Сетка крафта в инвентаре черепашки (4x4): 1,2,3 / 5,6,7 / 9,10,11.
local GRID_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

local function craft_step_table(step)
    local remaining = step.batches or 1
    local per_craft = (step.count or 0) / (step.batches or 1)

    -- какие предметы класть в сетку (на 1 крафт)
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
            if grid[i] then table.insert(cells, grid[i]) end
        end
    end
    if #cells == 0 then error("empty grid") end

    while remaining > 0 do
        -- 1) черепашка пустая, иначе turtle.craft не пройдёт
        if not empty_turtle(nil) then
            error("turtle not empty (vaults full?)")
        end

        -- 2) сколько крафтов можно сделать за прогон
        local want = math.min(remaining, 64)
        want = math.min(want, math.floor(7 * 64 / per_craft))
        if want < 1 then want = 1 end

        -- 3) набрать предметы прямо в слоты сетки
        local slotMap = {}
        local idx = 1
        for _, gid in ipairs(cells) do
            if idx > 9 then error("too many cells") end
            local cur = pull_into_slot(gid, GRID_SLOTS[idx], want)
            slotMap[idx] = cur
            idx = idx + 1
        end
        local runs = want
        for _, c in ipairs(slotMap) do runs = math.min(runs, c) end
        if runs < 1 then
            error("not enough in storage")
        end

        -- 4) крафт
        turtle.select(1)
        if not turtle.craft(runs) then
            error("turtle.craft failed")
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

local function craft_step_mechanism(step)
    local inName = resolve_name(step.mechanism_input) or step.mechanism_input
    local outName = resolve_name(step.mechanism_output) or step.mechanism_output
    local input = peripheral.wrap(inName)
    local output = peripheral.wrap(outName)
    if not input or not output then error("mechanism not found") end

    local result = step.result
    local per_craft = (step.count or 0) / (step.batches or 1)
    local batches = step.batches or 1

    -- чужой результат в выходе не считаем
    drain_to_vaults(output, step.destination)

    local remaining = batches
    while remaining > 0 do
        -- порция, которая влезает в 16 слотов черепашки (стаки по 64)
        local runs = remaining
        while runs > 1 do
            local slots = 0
            for _, ing in ipairs(step.ingredients) do
                slots = slots + math.ceil(ing.count * runs / 64)
            end
            if slots <= 16 then break end
            runs = math.floor(runs / 2)
        end

        if not empty_turtle(nil) then
            error("turtle not empty (vaults full?)")
        end

        -- набрать ингредиенты из любых вольтов
        local total = 0
        for _, ing in ipairs(step.ingredients) do
            local need = ing.count * runs
            local have = 0
            for slot = 1, 16 do
                if have >= need then break end
                local cur = pull_into_slot(ing.id, slot, need - have)
                if cur and cur > 0 then have = have + cur end
            end
            total = total + have
            if have < need then
                runs = math.min(runs, math.floor(have / ing.count))
            end
        end
        if runs < 1 then error("not enough in storage") end

        -- скормить машине и проверить, что она приняла
        local before = inventory_total(input)
        push_all_turtle_to(inName)
        local accepted = inventory_total(input) - before
        local per_batch = 0
        for _, ing in ipairs(step.ingredients) do per_batch = per_batch + ing.count end
        local fed = math.floor(accepted / per_batch)
        if fed < 1 then error("input won't accept") end
        empty_turtle(nil)

        -- ждать результат (бесконечно, с heartbeat)
        wait_for_output(output, result, per_craft * fed)

        drain_to_vaults(output, step.destination)
        remaining = remaining - fed
        print("mechanism: " .. tostring(result) .. " " ..
            tostring(batches - remaining) .. "/" .. tostring(batches))
    end
end

-- ======================= ИСПОЛНЕНИЕ ЗАКАЗА =======================
local function step_ready(step)
    for _, ing in ipairs(step.ingredients or {}) do
        if (stock[ing.id] or 0) < ing.count then return false end
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
local function process_order(order)
    local steps = order.steps or {}
    if #steps == 0 then
        report_fail(order, "no steps")
        return
    end

    scan_all_vaults()
    local done = {}
    local made = 0
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

-- Экран очереди: список заказов с сервера.
local function draw_queue_screen(orders)
    term.clear()
    term.setCursorPos(1, 1)
    local _, h = term.getSize()
    print("== Auto Crafter ==")
    print("Turtle: " .. tostring(turtleName))
    print("Vaults: " .. tostring(#activeVaults))
    print(configOk and "SERVER LINK: OK" or "NO SERVER CONNECTION!")
    print("Queue:")
    if not orders or #orders == 0 then
        print("  (пусто)")
        return
    end
    local max = math.max(1, h - 6)
    for i = 1, math.min(#orders, max) do
        local o = orders[i]
        local mark = "."
        if o.status == "queued" then mark = "[Q]"
        elseif o.status == "crafting" then mark = "[C]"
        elseif o.status == "done" then mark = "[OK]"
        elseif o.status == "failed" then mark = "[X]"
        elseif o.status == "missing" then mark = "[!]" end
        local name = tostring(o.item):match(":([^:]+)$") or tostring(o.item)
        if #name > 12 then name = name:sub(1, 12) end
        print(" " .. mark .. " " .. name .. " x" .. tostring(o.count))
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
