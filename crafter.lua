--[[
  ================================================================
  CC Storage Server -- crafter.lua (черепашка с верстаком)
  ================================================================
  Крафтит СТРОГО по плану с сервера:

    * верстак: рецепты из дампа/пользовательские -- сетка 3x3 в
      слотах 1,2,3 / 5,6,7 / 9,10,11 (CC:Tweaked), ингредиенты
      кладутся точно по позициям рецепта;
    * станки (mechanism): ингредиенты кладутся во вход по сети,
      результат ждём в выходе ПО КОЛИЧЕСТВУ (положил N -- ждём N).

  ТРЕБОВАНИЯ:
    - черепашка рядом с верстаком;
    - wired-модем (та же проводная сеть, что у вольтов и станков);
    - http включён в CC-конфиге.

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
    api_post("/api/heartbeat", { computer = os.computerID() })
end

-- ======================= КОНФИГ С СЕРВЕРА =======================
local SERVER_CONFIG = {}

local function fetch_server_config()
    local data = api_get("/api/config")
    if data and type(data) == "table" then
        SERVER_CONFIG = data
        return true
    end
    return false
end

-- Черепашка работает ТОЛЬКО с вольтами из конфига сайта.
local function cfg_vaults()
    local v = SERVER_CONFIG.vaults
    if type(v) == "table" and #v > 0 then return v end
    return CONFIG.fallback_storage or {}
end

-- ======================= ПЕРИФЕРИЯ =======================
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

local function wrap_storage(name)
    if not name or name == "" then
        return nil
    end
    local resolved = resolve_name(name) or name
    local ok, inv = pcall(peripheral.wrap, resolved)
    if ok and type(inv) == "table" and inv.list and inv.pushItems and inv.pullItems then
        return inv
    end
    return nil
end

local function scan_vault(inv)
    local out = {}
    local ok, list = pcall(inv.list)
    if not ok or type(list) ~= "table" then return nil end
    for _, item in pairs(list) do
        if type(item) == "table" and item.name then
            out[item.name] = (out[item.name] or 0) + (item.count or 0)
        end
    end
    return out
end

-- ======================= ИМЯ ЧЕРЕПАШКИ В СЕТИ =======================
local detected_turtle_name = nil

local function current_turtle_name()
    if detected_turtle_name then
        return detected_turtle_name
    end
    for _, n in ipairs(peripheral.getNames()) do
        if peripheral.getType(n) == "modem" then
            local m = peripheral.wrap(n)
            local isW = true
            pcall(function() isW = m.isWireless() end)
            if isW == false or isW == nil then
                local ok, name = pcall(m.getNameLocal)
                if ok and type(name) == "string" and name ~= "" then
                    detected_turtle_name = name
                    return name
                end
            end
        end
    end
    if SERVER_CONFIG.turtle_name and SERVER_CONFIG.turtle_name ~= "" then
        return SERVER_CONFIG.turtle_name
    end
    return CONFIG.fallback_turtle_name
end

-- ======================= СОСТОЯНИЕ =======================
local activeVaults = {}   -- вольты, среди которых ищем/кладём
local stock = {}          -- снимок содержимого
local configOk = false

local function scan_all_vaults()
    stock = {}
    for _, name in ipairs(activeVaults) do
        local inv = wrap_storage(name)
        if inv then
            local data = scan_vault(inv)
            if data then
                for id, cnt in pairs(data) do
                    stock[id] = (stock[id] or 0) + cnt
                end
            end
        end
    end
    return #activeVaults
end

-- ======================= ИНВЕНТАРЬ =======================
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

local function pull_from_inventory(inv, id, need)
    local ok, list = pcall(inv.list)
    if not ok or type(list) ~= "table" then return end
    local turtle_name = current_turtle_name()
    for slot, info in pairs(list) do
        if count_item(id) >= need then break end
        if type(info) == "table" and info.name == id then
            local take = math.min(need - count_item(id), info.count or 0)
            if take > 0 then
                pcall(inv.pushItems, turtle_name, slot, take)
            end
        end
    end
end

local function pull_from_any_vault(id, need)
    if count_item(id) >= need then return true end
    for _, vault_name in ipairs(activeVaults) do
        if count_item(id) >= need then break end
        local inv = wrap_storage(vault_name)
        if inv then
            pull_from_inventory(inv, id, need)
        end
    end
    return count_item(id) >= need
end

-- Набрать want предметов id ИМЕННО в слот to_slot (с проверкой предмета!)
local function pull_into_slot(id, to_slot, want)
    local turtle_name = current_turtle_name()
    local function have()
        local d = turtle.getItemDetail(to_slot)
        return (d and d.name == id) and d.count or 0
    end
    local cur = have()
    if cur >= want then return cur end
    for _, vault_name in ipairs(activeVaults) do
        local inv = wrap_storage(vault_name)
        if inv then
            local ok2, list = pcall(inv.list)
            if ok2 and type(list) == "table" then
                for slot, info in pairs(list) do
                    if type(info) == "table" and info.name == id then
                        local ok3, n = pcall(inv.pushItems, turtle_name, slot, want - cur, to_slot)
                        n = (ok3 and tonumber(n)) or 0
                        cur = cur + n
                        if cur >= want then return cur end
                        if n == 0 and cur > 0 then
                            return cur  -- слот упёрся в лимит стака
                        end
                    end
                end
            end
        end
    end
    return cur
end

-- Вольт сам забирает всё из черепашки
local function push_all_to_storage(storage)
    local turtle_name = current_turtle_name()
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d then
            pcall(storage.pullItems, turtle_name, s, d.count)
        end
    end
end

-- Всё из черепашки: destination (если задан), затем вольты по очереди
local function deliver(destination)
    local dest = wrap_storage(destination)
    if dest then
        push_all_to_storage(dest)
    end
    local turtle_name = current_turtle_name()
    for _, name in ipairs(activeVaults) do
        local inv = wrap_storage(name)
        if inv then
            local left = 0
            for s = 1, 16 do
                local d = turtle.getItemDetail(s)
                if d then
                    pcall(inv.pullItems, turtle_name, s, d.count)
                    if turtle.getItemDetail(s) then left = left + 1 end
                end
            end
            if left == 0 then return true end
        end
    end
    return false
end

local function empty_turtle(destination)
    deliver(destination)
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then
            return false
        end
    end
    return true
end

-- Забрать из инвентаря только предметы only_item -> destination/вольты
local function drain_only(inv, destination, only_item)
    if not inv then return end
    local ok, list = pcall(inv.list)
    if not ok or type(list) ~= "table" then return end
    local targets = {}
    if destination and destination ~= "" then
        table.insert(targets, resolve_name(destination) or destination)
    end
    for _, name in ipairs(activeVaults) do
        local rn = resolve_name(name) or name
        local dup = false
        for _, t in ipairs(targets) do
            if t == rn then dup = true end
        end
        if not dup then table.insert(targets, rn) end
    end
    for slot, info in pairs(list) do
        if type(info) == "table" and info.name == only_item and (info.count or 0) > 0 then
            local rest = info.count
            for _, tname in ipairs(targets) do
                if rest <= 0 then break end
                local okp, m = pcall(inv.pushItems, tname, slot, rest)
                if okp and m and m > 0 then rest = rest - m end
            end
        end
    end
end

-- ======================= КРАФТ НА ВЕРСТАКЕ =======================
-- У твоей черепашки поле крафта 4x4 (все 16 слотов), сетка 3x3 = угол:
-- 1,2,3 / 5,6,7 / 9,10,11 (проверено руками: кварц в 1, пластина в 5).
-- Если вдруг крафт не прошёл -- пробуем линейную раскладку 1-9.
local GRID_MODES = {
    { slots = { 1, 2, 3, 5, 6, 7, 9, 10, 11 } },    -- corner (4x4-поле)
    { slots = { 1, 2, 3, 4, 5, 6, 7, 8, 9 } },      -- linear
}
local gridOrder = { 1, 2 }

local function relocate_slots(fromSlots, toSlots)
    -- идём с конца, чтобы только что перенесённые предметы
    -- не попадали в следующие итерации (иначе предмет "ползёт")
    for i = 9, 1, -1 do
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
    -- какие предметы в какие слоты сетки класть (на 1 крафт)
    local cells = {}
    if step.shapeless then
        for _, ing in ipairs(step.ingredients or {}) do
            local per = ing.count / (step.batches or 1)
            for _ = 1, per do
                table.insert(cells, { pos = #cells + 1, id = ing.id })
            end
        end
    else
        local grid = step.grid or {}
        for i = 1, 9 do
            if grid[i] then
                table.insert(cells, { pos = i, id = grid[i] })
            end
        end
    end
    if #cells == 0 then
        return false, "empty recipe grid for " .. tostring(step.result)
    end

    local batches = math.max(1, step.batches or 1)
    local per_craft = math.max(1, math.floor((step.count or 1) / batches))
    local remaining = batches

    while remaining > 0 do
        if not empty_turtle(nil) then
            return false, "turtle can't empty itself - are all vaults full?"
        end
        local want = math.min(remaining, 64, math.floor(7 * 64 / per_craft))
        if want < 1 then want = 1 end

        -- набрать предметы в предпочтительную раскладку
        local slots = GRID_MODES[gridOrder[1]].slots
        local runs = want
        for _, cell in ipairs(cells) do
            local got = pull_into_slot(cell.id, slots[cell.pos], want)
            if got <= 0 then
                empty_turtle(nil)
                return false, "not enough in storage: " .. cell.id
            end
            if got < runs then runs = got end
        end

        -- крафт; если раскладка не подошла -- пробуем альтернативную
        local crafted = false
        for k = 1, #gridOrder do
            if k > 1 then
                relocate_slots(GRID_MODES[gridOrder[1]].slots,
                    GRID_MODES[gridOrder[k]].slots)
                print("  layout " .. tostring(gridOrder[1])
                    .. " failed, trying " .. tostring(gridOrder[k]))
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
            empty_turtle(nil)
            return false, "crafting failed for " .. tostring(step.result)
        end

        empty_turtle(step.destination)
        remaining = remaining - runs
        print("  " .. tostring(step.result) .. " +" .. (runs * per_craft)
            .. "  (" .. (batches - remaining) .. "/" .. batches .. ")")
    end
    return true
end

-- ======================= КРАФТ ЧЕРЕЗ СТАНОК =======================
local function count_in_inventory(inv, id)
    local ok, list = pcall(inv.list)
    if not ok or type(list) ~= "table" then return 0 end
    local total = 0
    for _, info in pairs(list) do
        if type(info) == "table" and info.name == id then
            total = total + (info.count or 0)
        end
    end
    return total
end

local function craft_step_mechanism(step)
    local mech_in = wrap_storage(step.mechanism_input or "")
    if not mech_in then
        return false, "cannot find mechanism input: " .. tostring(step.mechanism_input)
    end
    local mech_out = wrap_storage(step.mechanism_output or "")
    if not mech_out then
        return false, "cannot find mechanism output: " .. tostring(step.mechanism_output)
    end

    local batches = math.max(1, step.batches or 1)
    local per_craft = math.max(1, math.floor((step.count or 1) / batches))
    local total_needed = step.count or 1

    -- сколько каждого ингредиента нужно на 1 крафт
    local per_batch = {}
    for _, ing in ipairs(step.ingredients or {}) do
        if ing.id and ing.count and ing.count > 0 then
            table.insert(per_batch, { id = ing.id, count = ing.count / batches })
        end
    end
    if #per_batch == 0 then
        return false, "no ingredients for " .. tostring(step.result)
    end

    -- чужое в выходе не трогаем: убираем только НАШ результат
    drain_only(mech_out, step.destination, step.result)

    -- СТАНОК МОЖЕТ ДАВАТЬ ХЛАМ (шанс): собираем результат, пока его не
    -- наберётся total_needed -- если нужно, крафтим с излишком.
    local collected = 0
    while collected < total_needed do
        if not empty_turtle(nil) then
            return false, "turtle can't empty itself - are all vaults full?"
        end

        -- сколько крафтов осталось дособрать
        local remaining = math.max(1, math.ceil((total_needed - collected) / per_craft))

        -- размер порции: влезает в 16 слотов И не больше стака
        -- на ингредиент на крафт (депо больше стака не берёт)
        local runs = remaining
        local minPer = nil
        for _, ing in ipairs(per_batch) do
            if not minPer or ing.count < minPer then minPer = ing.count end
        end
        runs = math.min(runs, math.floor(64 / math.max(1, minPer)))
        while runs > 1 do
            local slots = 0
            for _, ing in ipairs(per_batch) do
                slots = slots + math.ceil(ing.count * runs / 64)
            end
            if slots <= 16 then break end
            runs = math.floor(runs / 2)
        end
        if runs < 1 then runs = 1 end

        -- набрать ВСЕ ингредиенты (каждый -- по количеству на порцию)
        local pulled = {}
        for _, ing in ipairs(per_batch) do
            pull_from_any_vault(ing.id, math.ceil(ing.count * runs))
            local got = count_item(ing.id)
            pulled[ing.id] = got
            if got < ing.count then
                empty_turtle(nil)
                return false, "not enough in storage: " .. ing.id
            end
            local can = math.floor(got / ing.count)
            if can < runs then runs = can end
        end

        -- скормить станку
        push_all_to_storage(mech_in)

        -- сколько станок реально принял (осталось в черепашке -- не принял)
        local fed_runs = runs
        for _, ing in ipairs(per_batch) do
            local fed = pulled[ing.id] - count_item(ing.id)
            local can = math.floor(fed / ing.count)
            if can < fed_runs then fed_runs = can end
        end
        if fed_runs < 1 then
            empty_turtle(nil)
            return false, "mechanism input won't accept items: " .. tostring(step.mechanism_input)
        end
        empty_turtle(nil)

        -- ждём результат: либо накопилось нужное, либо 3 минуты без
        -- прогресса (станок наделал хлам) -- тогда забираем что есть
        -- и докрафчиваем дальше (излишек ничему не мешает)
        local need_now = per_craft * fed_runs
        local waited = 0
        local lastHave = 0
        while true do
            local have = count_in_inventory(mech_out, step.result)
            if have >= need_now then break end
            if have ~= lastHave then
                lastHave = have
                waited = 0
            end
            os.sleep(3)
            waited = waited + 3
            if waited >= 180 then break end
            if waited % 30 == 0 then
                heartbeat()
                print("  ...waiting: " .. tostring(step.result)
                    .. " " .. tostring(have) .. "/" .. tostring(need_now))
            end
        end

        local made = count_in_inventory(mech_out, step.result)
        drain_only(mech_out, step.destination, step.result)
        collected = collected + made
        print("  " .. tostring(step.result) .. " +" .. made
            .. "  (" .. math.min(collected, total_needed) .. "/" .. total_needed .. ")")
    end
    return true
end

local function craft_step(step)
    if step.method == "mechanism" then
        return craft_step_mechanism(step)
    end
    return craft_step_table(step)
end

-- ======================= ЗАКАЗЫ =======================
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

local function report_progress(order, made)
    api_post("/api/orders/progress", { order = order.id, step = made, status = "ok" })
end

local function report_fail(order, msg)
    api_post("/api/orders/progress", { order = order.id, status = "fail", msg = tostring(msg) })
end

-- Как AE2: проходим по шагам, выполняем готовые, после каждого успеха
-- пересканируем. Продолжаем с step_done (после рестарта не перекрафчиваем).
local function process_order(order)
    local steps = order.steps or {}
    if #steps == 0 then
        report_fail(order, "no steps")
        return
    end

    -- ищем ингредиенты не только в вольтах конфига, но и в вольтах,
    -- куда шаги складывают результаты (destination)
    activeVaults = {}
    for _, v in ipairs(cfg_vaults()) do
        table.insert(activeVaults, v)
    end
    for _, s in ipairs(steps) do
        if s.destination and s.destination ~= "" then
            local dup = false
            for _, v in ipairs(activeVaults) do
                if v == s.destination then dup = true end
            end
            if not dup then table.insert(activeVaults, s.destination) end
        end
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
            if not done[i] then
                if step_ready(step) then
                    print("Step " .. (made + 1) .. "/" .. #steps .. ": "
                        .. tostring(step.result) .. " x" .. tostring(step.count))
                    local ok, err = craft_step(step)
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
        end
        if not progressed then
            -- вернуть набранное в вольты и сообщить об ошибке
            pcall(empty_turtle, nil)
            report_fail(order, lastErr or "no progress")
            return
        end
    end
end

-- ======================= МОНИТОР =======================
-- Монитор только вплотную к черепашке (любой гранью).
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

local function wline(s, w)
    local t = tostring(s or "")
    if #t > w then t = t:sub(1, w) end
    term.write(t .. string.rep(" ", w - #t))
    print("")
end

local function draw_queue_screen(orders)
    term.clear()
    term.setCursorPos(1, 1)
    local w, _ = term.getSize()
    wline("== Auto Crafter ==", w)
    wline("Turtle: " .. tostring(current_turtle_name()), w)
    wline("Vaults: " .. tostring(#cfg_vaults()), w)
    wline(configOk and "SERVER LINK: OK" or "NO SERVER CONNECTION!", w)
    wline("Queue:", w)
    if not orders or #orders == 0 then
        wline("  (пусто)", w)
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
            wline(" " .. mark .. " " .. name .. " x" .. tostring(cnt), w)
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
    fetch_server_config()

    local iter = 0
    while true do
        iter = iter + 1
        if iter % 4 == 1 then
            configOk = fetch_server_config()
        end

        -- heartbeat всегда, чтобы сайт видел черепашку на связи
        heartbeat()

        activeVaults = cfg_vaults()
        local anyVault = false
        for _, v in ipairs(activeVaults) do
            if wrap_storage(v) then anyVault = true break end
        end

        if not anyVault then
            term.clear()
            term.setCursorPos(1, 1)
            print("NO VAULT REACHABLE")
            print("Добавь вольты в настройках сайта")
            print("или проверь проводную сеть!")
            os.sleep(5)
        else
            local data = api_get("/api/orders/next")
            if data and data.order then
                term.clear()
                term.setCursorPos(1, 1)
                print("Order #" .. tostring(data.order.id) .. ": "
                    .. tostring(data.order.item) .. " x" .. tostring(data.order.count))
                pcall(process_order, data.order)
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
