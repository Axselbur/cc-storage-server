--[[
  ================================================================
  CC Storage Server -- main.lua (компьютер у хранилищ)
  ================================================================
  Сканирует вольты (Create: Connected item vaults), шлёт содержимое
  на сервер, гоняет логистику (упаковщики -> цель, буферный сундук ->
  вольты) и выводит статус на внешний монитор.

  УСТАНОВКА:
    wget https://<app>.onrender.com/main.lua startup ; reboot

  ТРЕБОВАНИЯ К СЕТИ:
    - компьютер подключён к вольтам проводной сетью (wired modem) или
      стоит вплотную к одному вольту;
    - в CC-конфиге включён http (http.enabled = true);
    - компьютер ходит на ПУБЛИЧНЫЙ адрес (https://...onrender.com),
      127.0.0.1 для него -- сам Minecraft-сервер.
  ================================================================
]]

-- ======================= SETTINGS =======================
local CONFIG = {
    -- Адрес сервера на Render.
    server_url = "https://cc-storage-server.onrender.com",

    -- Ключ устройства. ДОЛЖЕН совпадать с переменной DEVICE_KEY на
    -- Render. Это НЕ пароль сайта -- только для API-запросов из игры.
    device_key = "-77QIbhF2zXqjZgrhWeozH_ycB8pnTf2",

    scan_interval = 20,      -- как часто сканировать вольты и слать на сервер, с
    transfer_interval = 1,   -- период логистики, с
    auto_discover_fallback = true,  -- искать вольты по маске, если в конфиге пусто

    -- Fallback-значения на случай, если сервер не отдал конфиг.
    fallback_vaults = {},
    fallback_packagers = {},
    fallback_packager_target = "",
    fallback_buffer_chest = "",
    fallback_auto_balance = true,
    fallback_auto_balance_interval = 600,
    fallback_vault_capacity = 4096,

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

local function cfg_vaults()
    local v = SERVER_CONFIG.vaults
    if type(v) == "table" and #v > 0 then return v end
    return CONFIG.fallback_vaults or {}
end

local function cfg_packagers()
    local v = SERVER_CONFIG.packagers
    if type(v) == "table" and #v > 0 then return v end
    return CONFIG.fallback_packagers or {}
end

local function cfg_packager_target()
    local v = SERVER_CONFIG.packager_target
    if type(v) == "string" and v ~= "" then return v end
    return CONFIG.fallback_packager_target or ""
end

local function cfg_buffer_chest()
    local v = SERVER_CONFIG.buffer_chest
    if type(v) == "string" and v ~= "" then return v end
    return CONFIG.fallback_buffer_chest or ""
end

local function cfg_auto_balance()
    local v = SERVER_CONFIG.auto_balance
    if type(v) == "boolean" then return v end
    return CONFIG.fallback_auto_balance
end

local function cfg_auto_balance_interval()
    local v = SERVER_CONFIG.auto_balance_interval
    if type(v) == "number" and v > 0 then return v end
    return CONFIG.fallback_auto_balance_interval
end

local function cfg_vault_capacity()
    local v = SERVER_CONFIG.vault_capacity
    if type(v) == "number" and v > 0 then return v end
    return CONFIG.fallback_vault_capacity or 4096
end

-- ======================= ПЕРИФЕРИЯ =======================
-- resolve_name: точное имя периферии, иначе сравнение без учёта
-- регистра/разделителей (Create_Packager_1 ~ create:packager_1),
-- иначе совпадение по хвостовому числу.
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

-- discover_vaults: все периферии, похожие на вольты/силосы.
-- Принимаем любые варианты имён: create:item_vault_1,
-- create_connected:item_silo_75, Create_Connected_Item_Silo_75 и т.п.
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

-- scan_vault: содержимое одного вольта -> {id: count}
local function scan_vault(inv)
    local out = {}
    local ok, list = pcall(inv.list)
    if not ok then return nil end
    for _, item in pairs(list) do
        out[item.name] = (out[item.name] or 0) + item.count
    end
    return out
end

-- ======================= ЛОГИСТИКА =======================
local function push_all(inv, target)
    local moved = 0
    local ok, list = pcall(inv.list)
    if not ok then return 0 end
    for slot, item in pairs(list) do
        if item.count > 0 then
            local okp, m = pcall(inv.pushItems, target, slot, item.count)
            if okp and m and m > 0 then moved = moved + m end
        end
    end
    return moved
end

local function logistics_pass(active_vaults)
    local moved = 0

    -- 1) каждый упаковщик -> packager_target
    local target = cfg_packager_target()
    if target ~= "" then
        local tName = resolve_name(target) or target
        for _, pname in ipairs(cfg_packagers()) do
            local inv = get_inventory(pname)
            if inv then
                moved = moved + push_all(inv, tName)
            end
        end
    end

    -- 2) буферный сундук -> раздать по вольтам по слоту
    local buf = get_inventory(cfg_buffer_chest())
    if buf then
        local ok, list = pcall(buf.list)
        if ok then
            for slot, item in pairs(list) do
                local count = item.count
                if count > 0 then
                    for _, vname in ipairs(active_vaults) do
                        local vN = resolve_name(vname) or vname
                        local okp, m = pcall(buf.pushItems, vN, slot, count)
                        if okp and m and m > 0 then
                            count = count - m
                            moved = moved + m
                        end
                        if count <= 0 then break end
                    end
                end
            end
        end
    end

    return moved
end

-- ======================= ОТПРАВКА НА СЕРВЕР =======================
local function send_to_server(payload)
    return api_post("/api/items", payload)
end

-- ======================= МОНИТОР =======================
local monitor = nil

-- ЖЁСТКОЕ ПРАВИЛО: монитор только вплотную к компьютеру (любой гранью),
-- по сети (wired-модемом) мониторы не подхватываются.
local DIRECT_SIDES = { top = true, bottom = true, left = true, right = true,
                       front = true, back = true }

local function setup_monitor()
    if not CONFIG.use_monitor then
        return false
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
        return false
    end
    print("Output -> external monitor (" .. mName .. ")")
    monitor = peripheral.wrap(mName)
    if monitor.setTextScale then
        pcall(monitor.setTextScale, CONFIG.monitor_text_scale)
    end
    term.redirect(monitor)
    return true
end

local function fmt_bar(name, total, capacity)
    local label = name:gsub("^.*:", "")
    if #label > 14 then label = label:sub(1, 14) end
    label = label .. string.rep(" ", 14 - #label)
    local cap = math.max(1, capacity or 1)
    local clamped = math.min(total, cap)
    local pct = math.floor(clamped * 100 / cap)
    local fill = math.floor(clamped * 10 / cap)
    local bar = string.rep("#", fill) .. string.rep("-", 10 - fill)
    return label .. " " .. bar .. " " .. tostring(pct) .. "% (" .. tostring(total) .. ")"
end

local function draw_status(found, totalVaults, kinds, total, logisticsStatus, serverLink, missing, vaultStats, capacity)
    term.clear()
    term.setCursorPos(1, 1)
    local _, h = term.getSize()
    print("== Storage Monitor ==")
    print("Vaults: " .. tostring(found) .. "/" .. tostring(totalVaults)
        .. " | Items: " .. tostring(kinds) .. "/" .. tostring(total))
    if serverLink then
        print("SERVER LINK: OK")
    else
        print("NO SERVER CONNECTION!")
    end

    local rows = h - 3
    if #missing > 0 then rows = rows - 1 end
    local shown = 0
    for _, v in ipairs(vaultStats or {}) do
        if shown >= rows then break end
        print(fmt_bar(v.name, v.total, capacity))
        shown = shown + 1
    end
    if #missing > 0 and shown < rows then
        print("Missing: " .. table.concat(missing, ", "))
    end
end

-- ======================= БАЛАНСИРОВКА ХРАНИЛИЩ =======================
-- Один list() на вольт -> модель {total, slots}. Перекладываем самый
-- большой стак, который влезает в разницу, из самого полного в самый
-- пустой. Делить стаки нельзя; лимит 400 стаков за запуск.
local active_vaults = {}

local function balance_vaults()
    local model = {}

    local function scan_into(name)
        local inv = get_inventory(name)
        if not inv then return nil end
        local ok, list = pcall(inv.list)
        if not ok then return nil end
        local total = 0
        local slots = {}
        for slot, item in pairs(list) do
            slots[slot] = item.count
            total = total + item.count
        end
        return { name = name, total = total, slots = slots }
    end

    for _, name in ipairs(active_vaults) do
        local m = scan_into(name)
        if m then table.insert(model, m) end
    end
    if #model < 2 then
        return "done", 0
    end

    local blocked = {}
    local moved = 0
    local steps = 0

    while steps < 400 do
        -- если у самого полного есть неизвестные слоты -- пересканировать
        table.sort(model, function(a, b) return a.total > b.total end)
        local full = model[1]
        if full.slots[-1] then
            local fresh = scan_into(full.name)
            if fresh then
                full.total = fresh.total
                full.slots = fresh.slots
            end
        end

        -- подобрать пару: самый полный -> самый пустой, не заблокированную
        local fromV, toV = nil, nil
        for i = 1, #model do
            for j = #model, 1, -1 do
                if i < j and not blocked[model[i].name .. "->" .. model[j].name] then
                    fromV, toV = model[i], model[j]
                    break
                end
            end
            if fromV then break end
        end
        if not fromV then break end

        local diff = fromV.total - toV.total
        if diff < 1 then break end

        -- самый большой стак, который влезает в разницу
        local bestSlot, bestCount = nil, 0
        for slot, cnt in pairs(fromV.slots) do
            if cnt > bestCount and cnt <= diff then
                bestSlot, bestCount = slot, cnt
            end
        end
        if not bestSlot then
            blocked[fromV.name .. "->" .. toV.name] = true
            steps = steps + 1
        else
            local fromInv = get_inventory(fromV.name)
            local okp, m = pcall(fromInv.pushItems,
                resolve_name(toV.name) or toV.name, bestSlot, bestCount)
            if okp and m and m > 0 then
                moved = moved + m
                fromV.total = fromV.total - m
                toV.total = toV.total + m
                fromV.slots[bestSlot] = bestCount - m
                if fromV.slots[bestSlot] <= 0 then fromV.slots[bestSlot] = nil end
                toV.slots[-1] = (toV.slots[-1] or 0) + m
            else
                blocked[fromV.name .. "->" .. toV.name] = true
            end
            steps = steps + 1
        end

        if steps % 10 == 0 then
            api_post("/api/balance/progress",
                { status = "running", moved = moved, message = "перекладываю" })
            os.sleep(0)
        end
    end

    return "done", moved
end

local function check_balance_job()
    local data = api_get("/api/balance")
    if not data or data.status ~= "requested" then
        return false
    end
    api_post("/api/balance/progress", { status = "running", moved = 0, message = "начал" })
    local ok, err = pcall(function()
        local status, moved = balance_vaults()
        api_post("/api/balance/progress",
            { status = status, moved = moved, message = "готово" })
    end)
    if not ok then
        api_post("/api/balance/progress",
            { status = "failed", moved = 0, message = tostring(err) })
    end
    return true
end

-- ======================= ГЛАВНЫЙ ЦИКЛ =======================
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("CC Storage Server: storage computer")
    print("Server: " .. CONFIG.server_url)
    setup_monitor()

    local tick = 0
    local server_ok = false
    local kinds, total = 0, 0
    local lastLogistics = "idle"
    local missing = {}
    local vaultData = {}
    local lastAutoBalance = os.epoch("utc")

    while true do
        tick = tick + 1

        -- логистика раз в transfer_interval (каждый тик)
        local okL, moved = pcall(logistics_pass, active_vaults)
        lastLogistics = okL and (moved > 0 and ("moved " .. tostring(moved)) or "idle")
            or "error"

        -- полный цикл раз в scan_interval
        if tick % CONFIG.scan_interval == 0 then
            local okCycle, errCycle = pcall(function()
                server_ok = fetch_server_config()
                check_balance_job()

                -- автобалансировка: держим вольты заполненными равномерно
                local nowMs = os.epoch("utc")
                if cfg_auto_balance() and
                   (nowMs - lastAutoBalance) > cfg_auto_balance_interval() * 1000 then
                    lastAutoBalance = nowMs
                    api_post("/api/balance/progress",
                        { status = "running", moved = 0, message = "автобалансировка" })
                    local okB, errB = pcall(function()
                        local stB, mvB = balance_vaults()
                        api_post("/api/balance/progress",
                            { status = stB, moved = mvB, message = "автобалансировка" })
                    end)
                    if not okB then
                        api_post("/api/balance/progress",
                            { status = "failed", moved = 0, message = tostring(errB) })
                    end
                end

                -- собрать список вольтов: конфиг + авто-обнаружение
                local names = {}
                for _, n in ipairs(cfg_vaults()) do
                    table.insert(names, n)
                end
                if CONFIG.auto_discover_fallback then
                    for _, n in ipairs(discover_vaults()) do
                        local found = false
                        for _, c in ipairs(names) do
                            if c == n then found = true break end
                        end
                        if not found then table.insert(names, n) end
                    end
                end

                -- сканирование
                active_vaults = {}
                missing = {}
                local items = {}
                vaultData = {}
                for _, name in ipairs(names) do
                    local inv = get_inventory(name)
                    if inv then
                        local data = scan_vault(inv)
                        if data then
                            table.insert(active_vaults, name)
                            vaultData[name] = data
                            for id, cnt in pairs(data) do
                                items[id] = (items[id] or 0) + cnt
                            end
                        else
                            table.insert(missing, name)
                        end
                    else
                        table.insert(missing, name)
                    end
                end

                kinds = 0
                total = 0
                for _ in pairs(items) do kinds = kinds + 1 end
                for _, cnt in pairs(items) do total = total + cnt end

                -- отправить на сервер
                local payload = {
                    source = "computercraft",
                    computer = os.computerID(),
                    time = os.epoch("utc"),
                    items = items,
                    vaults = vaultData,
                    missing = missing,
                }
                server_ok = send_to_server(payload)
            end)
            if not okCycle then
                server_ok = false
                print("Cycle error: " .. tostring(errCycle))
            end

            local vaultStats = {}
            for _, name in ipairs(active_vaults) do
                local vt = 0
                for _, cnt in pairs(vaultData[name] or {}) do vt = vt + cnt end
                table.insert(vaultStats, { name = name, total = vt })
            end
            table.sort(vaultStats, function(a, b) return a.total > b.total end)

            draw_status(#active_vaults, #cfg_vaults(), kinds, total,
                lastLogistics, server_ok, missing, vaultStats, cfg_vault_capacity())
        end

        os.sleep(CONFIG.transfer_interval)
    end
end

local ok, err = pcall(main)
if not ok then
    term.redirect(term.native())
    printError("Error: " .. tostring(err))
end
