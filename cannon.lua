--[[
  ================================================================
  CC Storage Server -- cannon.lua (черепашка-заправщик пушек)
  ================================================================
  Разгружает основной скрипт: следит ТОЛЬКО за автопушками.
  Каждые 30 сек проверяет патроны в пушке; если расходуются --
  раз в 5 сек; пусто -- доливает из вольтов по стаку до упора.

  УСТАНОВКА:
    wget https://<app>.onrender.com/cannon.lua startup ; reboot
  ================================================================
]]

local CONFIG = {
    server_url = "https://cc-storage-server.onrender.com",
    device_key = "-77QIbhF2zXqjZgrhWeozH_ycB8pnTf2",

    fallback_storage = {},    -- вольты, если сервер не отдал конфиг
    fallback_cannons = {},    -- пушки, если сервер не отдал конфиг

    use_monitor = true,
    monitor_text_scale = 0.5,
}

if not turtle then
    printError("This program must run on a TURTLE.")
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

-- ======================= КОНФИГ =======================
local SERVER_CONFIG = {}

local function fetch_server_config()
    local data = api_get("/api/config")
    if data and type(data) == "table" then
        SERVER_CONFIG = data
        return true
    end
    return false
end

local function cfg_vaults()
    local v = SERVER_CONFIG.vaults
    if type(v) == "table" and #v > 0 then return v end
    return CONFIG.fallback_storage or {}
end

local function cfg_cannons()
    local c = SERVER_CONFIG.cannons
    if type(c) == "table" and #c > 0 then return c end
    return CONFIG.fallback_cannons or {}
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

local function get_inventory(name)
    local n = resolve_name(name)
    if not n then return nil end
    local inv = peripheral.wrap(n)
    if inv and inv.list then return inv end
    return nil
end

-- ======================= СПЕКИ ПРЕДМЕТОВ =======================
-- id[comp=...]: без компонентов -- только чистый предмет (NBT пустое),
-- с компонентами -- обязательны все маркеры в NBT.
local function parse_item_spec(spec)
    local s = tostring(spec)
    local base = s
    local b = string.find(s, "[", 1, true)
    if b then
        base = string.sub(s, 1, b - 1)
    end
    local markers = {}
    for token in string.gmatch(s, "[%w_]+:[%w_/]+") do
        markers[token] = true
    end
    markers[base] = nil
    return base, markers
end

local function item_matches_spec(detail, base, markers)
    if not detail or detail.name ~= base then
        return false
    end
    local nbtStr = tostring(detail.nbt or "")
    local hasMarkers = false
    for _ in pairs(markers) do hasMarkers = true break end
    if not hasMarkers then
        return nbtStr == ""
    end
    for marker in pairs(markers) do
        if not string.find(nbtStr, marker, 1, true) then
            return false
        end
    end
    return true
end

local function find_slot_spec(inv, base, markers)
    local ok, list = pcall(inv.list)
    if not ok or type(list) ~= "table" then return nil end
    for slot, info in pairs(list) do
        if type(info) == "table" and info.name == base then
            local match = true
            if next(markers) ~= nil then
                local ok2, det = pcall(inv.getItemDetail, slot)
                match = ok2 and item_matches_spec(det, base, markers)
            end
            if match then
                return slot
            end
        end
    end
    return nil
end

local function cannon_ammo_count(cannon, base, markers)
    if not cannon then return nil end
    local ok, list = pcall(cannon.list)
    if not ok or type(list) ~= "table" then return nil end
    local total = 0
    for slot, info in pairs(list) do
        if type(info) == "table" and info.name == base then
            local match = true
            if next(markers) ~= nil then
                local ok2, det = pcall(cannon.getItemDetail, slot)
                match = ok2 and item_matches_spec(det, base, markers)
            end
            if match then
                total = total + (info.count or 0)
            end
        end
    end
    return total
end

-- ======================= КОРМЛЕНИЕ =======================
local cannonState = {}   -- name -> { nextCheck, lastCount, fast, status }

local function cannon_pass()
    local cannons = cfg_cannons()
    if #cannons == 0 then return 0 end
    local now = os.epoch("utc")
    local fed = 0

    for _, c in ipairs(cannons) do
        local st = cannonState[c.name] or
            { nextCheck = 0, lastCount = nil, fast = false, status = "?" }
        cannonState[c.name] = st
        if now < st.nextCheck then
            -- ещё не пора
        else
            local cName = resolve_name(c.name) or c.name
            local cannon = get_inventory(cName)
            local base, markers = parse_item_spec(c.ammo)
            local count = cannon_ammo_count(cannon, base, markers)

            if count ~= nil and st.lastCount ~= nil and count < st.lastCount then
                st.fast = true
            elseif st.fast and count ~= nil and st.lastCount ~= nil and count >= st.lastCount then
                st.fast = false
            end
            st.lastCount = count

            local isEmpty = (count == nil) or (count <= 0)
            if isEmpty then
                local hadAmmo = false
                local pushedThis = 0
                local attempts = 0
                while attempts < 64 do
                    attempts = attempts + 1
                    local vault, vName, vSlot = nil, nil, nil
                    for _, vname in ipairs(cfg_vaults()) do
                        local inv = get_inventory(vname)
                        if inv then
                            local slot = find_slot_spec(inv, base, markers)
                            if slot then
                                vault, vName, vSlot = inv, vname, slot
                                break
                            end
                        end
                    end
                    if not vault then break end
                    hadAmmo = true
                    -- основное направление: вольт толкает в пушку
                    local okp, m = pcall(vault.pushItems, cName, vSlot, 64)
                    if okp and m and m > 0 then
                        pushedThis = pushedThis + m
                    else
                        -- обратное направление: пушка сама тянет из вольта
                        local okc, mc = pcall(cannon.pullItems, vName, vSlot, 64)
                        if okc and mc and mc > 0 then
                            pushedThis = pushedThis + mc
                        else
                            break
                        end
                    end
                end
                fed = fed + pushedThis
                if not hadAmmo then
                    st.status = "NO AMMO IN VAULTS"
                    st.nextCheck = now + 30000
                elseif pushedThis > 0 then
                    st.status = "feeding"
                    st.nextCheck = now + 5000
                else
                    st.status = "PUSH FAILED"
                    st.nextCheck = now + 5000
                end
            elseif st.fast then
                st.status = "firing"
                st.nextCheck = now + 5000
            else
                st.status = "ok (" .. tostring(count) .. ")"
                st.nextCheck = now + 30000
            end
        end
    end

    return fed
end

-- ======================= МОНИТОР =======================
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
        print("No monitor attached (touch only)")
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

local function draw_screen(configOk, errText)
    term.clear()
    term.setCursorPos(1, 1)
    local w, _ = term.getSize()
    wline("== Cannon Feeder ==", w)
    wline("Cannons: " .. tostring(#cfg_cannons()), w)
    wline(configOk and "SERVER LINK: OK" or "NO SERVER CONNECTION!", w)
    for _, c in ipairs(cfg_cannons()) do
        local st = cannonState[c.name]
        local short = tostring(c.name):gsub("^.*:", "")
        wline(" " .. short .. ": " .. tostring(st and st.status or "?"), w)
    end
    if errText then
        wline("ERROR: " .. tostring(errText), w)
    end
end

-- ======================= ГЛАВНЫЙ ЦИКЛ =======================
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("CC Storage Server: cannon feeder")
    print("Server: " .. CONFIG.server_url)
    setup_monitor()

    local configOk = fetch_server_config()
    local cannonError = nil
    local iter = 0
    local lastBeat = 0
    while true do
        iter = iter + 1
        if iter % 4 == 1 then
            configOk = fetch_server_config()
        end
        -- heartbeat раз в 30 секунд, а не каждую секунду
        -- (1 тик = 1 команда: частый HTTP сам создаёт лаги)
        local nowMs = os.epoch("utc")
        if nowMs - lastBeat > 30000 then
            heartbeat()
            lastBeat = nowMs
        end
        local okc, errc = pcall(cannon_pass)
        cannonError = okc and nil or tostring(errc)
        draw_screen(configOk, cannonError)
        os.sleep(1)
    end
end

local ok, err = pcall(main)
if not ok then
    term.redirect(term.native())
    printError("Error: " .. tostring(err))
end
