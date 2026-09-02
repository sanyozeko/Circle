local ADDON, ns = ...

-- Ежедневные и еженедельные задания WoW Circle, без Questie.
-- Вся логика состояния здесь, окно - в UI.lua.

CircleDW = ns

-- ===========================================================================
--  СПИСОК ЗАДАНИЙ
-- ===========================================================================
-- На аккаунт можно выполнить ОДНО задание из группы за период: одно из четырёх
-- ежедневных в день и одно из семи еженедельных в неделю. Поэтому напоминание
-- одно на группу, и один сданный квест закрывает всю группу до сброса.
ns.QUESTS = {
    [50016] = { kind = "weekly", name = "Испытание подземелий" },
    [50017] = { kind = "weekly", name = "Испытание рейда" },
    [50018] = { kind = "weekly", name = "Испытание полей боя" },
    [50019] = { kind = "weekly", name = "Испытание полей боя: урон" },
    [50020] = { kind = "weekly", name = "Испытание полей боя: исцеление" },
    [50021] = { kind = "weekly", name = "Испытание арены: 2х2 / 3х3" },
    [50022] = { kind = "weekly", name = "Испытание арены: 1х1 / 3х3 соло" },

    [50023] = { kind = "daily",  name = "Ежедневное испытание подземелий" },
    [50024] = { kind = "daily",  name = "Ежедневное испытание полей боя" },
    [50025] = { kind = "daily",  name = "Ежедневное испытание арены" },
    [50026] = { kind = "daily",  name = "Ежедневное испытание рейда" },
}

ns.KINDS = { "daily", "weekly" }
ns.KIND_LABEL = { daily = "Ежедневное", weekly = "Еженедельное" }

-- День недельного сброса: 1=Вс, 2=Пн, 3=Вт, 4=Ср, 5=Чт, 6=Пт, 7=Сб.
-- На Circle - среда 04:00. Час берётся с сервера через GetQuestResetTime.
local WEEKLY_RESET_WDAY = 4

-- Путь по пунктам серверного меню до списка заданий.
local MENU_COMMAND = ".menu"
local MENU_PATH = {
    daily  = { "Особые задания", "Ежедневные испытания" },
    weekly = { "Особые задания", "Еженедельные испытания" },
}

-- Свой звук напоминания. Формат тот же, что у рабочих файлов DBM в этом
-- клиенте: MPEG-1 Layer III, 44100 Гц, 128 кбит/с, без ID3-тега.
local ALERT_SOUND = "Interface\\AddOns\\Circle-DailyWeekly\\Sounds\\alert.mp3"

local QUERY_THROTTLE = 60
local QUERY_INTERVAL = 300

-- ===========================================================================

local floor, format = math.floor, string.format

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99Circle|r: " .. tostring(msg))
end
ns.Print = Print

local function Norm(text)
    return (tostring(text or ""):lower():gsub("%s+", " "))
end

-- Способов показать состояние несколько (значок, кнопка на миникарте, список),
-- поэтому Core их не знает: каждый модуль отображения сам себя регистрирует.
ns.builders = {}
ns.renderers = {}

-- Сломанный модуль отображения не должен ронять остальные, но и молча
-- исчезать он тоже не должен: об ошибке сообщаем один раз.
local reported = {}

local function Run(fn, what)
    local ok, err = pcall(fn)
    if (not ok) and (not reported[fn]) then
        reported[fn] = true
        Print("|cffff4040ошибка|r в " .. what .. ": " .. tostring(err))
    end
end

function ns.Build()
    for _, build in ipairs(ns.builders) do Run(build, "сборке интерфейса") end
end

function ns.Refresh()
    for _, render in ipairs(ns.renderers) do Run(render, "отрисовке") end
end

-- Кнопка у миникарты есть всегда: это постоянная точка входа, чтобы за
-- настройками и меню заданий не приходилось лезть в интерфейс игры.
-- Скрыть её можно, но по умолчанию она включена.
function ns.MinimapShown()
    return ns.DB().minimap ~= false
end

-- Дополнительное отображение поверх кнопки:
--   "none"  - ничего, только кнопка
--   "badge" - значок, видно лишь пока есть незакрытое дело
--   "list"  - список строк в стиле трекера Questie
function ns.Style()
    local style = ns.DB and ns.DB().style
    if style == "minimap" then return "none" end   -- значение из старых версий
    return style or "none"
end

-- Открыть свою страницу в настройках игры. В 3.3.5a первый вызов только
-- разворачивает список категорий, поэтому зовём дважды - иначе откроется
-- не та страница.
function ns.OpenOptions()
    if not (InterfaceOptionsFrame_OpenToCategory and ns.optionsPanel) then return end
    InterfaceOptionsFrame_OpenToCategory(ns.optionsPanel)
    InterfaceOptionsFrame_OpenToCategory(ns.optionsPanel)
end

-- ------------------------------------------------------------- сохранения --
local function DB()
    CircleDailyWeeklyDB = CircleDailyWeeklyDB or {}
    return CircleDailyWeeklyDB
end
ns.DB = DB

-- SavedVariables общие на весь игровой аккаунт, а вот квесты - нет: x1, x4,
-- x100 и прочие реалмы это отдельные серверы со своими базами. Сдача на одном
-- реалме ничего не закрывает на другом, поэтому всё разложено по реалмам.
local function Realm()
    local realm = GetRealmName and GetRealmName()
    if realm and realm ~= "" then return realm end
    return "?"
end
ns.Realm = Realm

-- Отметки о выполнении: общие для всех персонажей аккаунта на этом реалме.
local function AccountDone()
    local db = DB()
    db.done = db.done or {}
    local realm = Realm()
    db.done[realm] = db.done[realm] or {}
    return db.done[realm]
end
ns.AccountDone = AccountDone

-- Список награждённых квестов у сервера означает "когда-то выполнял", а не
-- "выполнил в этом периоде": при сбросе ядро его не чистит. Поэтому id, по
-- которому отметка уже протухла, запоминается — иначе ответ сервера ставил бы
-- её заново каждый раз, и задание вечно числилось бы выполненным.
-- Именно множество, а не одно значение: сервер накапливает все когда-либо
-- выполненные задания, и после каждого сброса воскрешал бы отметку через
-- следующий по счёту id.
local function StaleSet(kind)
    local db = DB()
    db.stale = db.stale or {}
    local realm = Realm()
    db.stale[realm] = db.stale[realm] or {}
    local set = db.stale[realm][kind]
    if type(set) ~= "table" then       -- переживаем старый формат: одно число
        set = {}
        db.stale[realm][kind] = set
    end
    return set
end

-- Снять отметку, если её срок вышел. Вызывается и при отрисовке, и до разбора
-- ответа сервера: иначе ответ успевал бы воскресить отметку раньше, чем мы
-- заметим, что период уже закончился.
local function PurgeExpired(kind)
    local record = AccountDone()[kind]
    if record and record.expires and time() >= record.expires then
        if record.questId then StaleSet(kind)[record.questId] = true end
        AccountDone()[kind] = nil
    end
end

-- Срезы состояния по персонажам: клиент видит журнал только текущего.
local function Snapshots()
    local db = DB()
    db.chars = db.chars or {}
    local realm = Realm()
    db.chars[realm] = db.chars[realm] or {}
    return db.chars[realm]
end

-- --------------------------------------------------------------- журнал ---
-- Один проход вместо поиска по каждому заданию: на 3.3.5a ID лежит девятым
-- значением GetQuestLogTitle.
local logIndexMap, logIndexDirty = {}, true

local function LogIndex()
    if logIndexDirty then
        local map = {}
        local count = GetNumQuestLogEntries and GetNumQuestLogEntries() or 0
        for i = 1, count do
            local _, _, _, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
            if id and not isHeader then map[id] = i end
        end
        logIndexMap, logIndexDirty = map, false
    end
    return logIndexMap
end

local function InQuestLog(questId)
    return LogIndex()[questId] ~= nil
end
ns.InQuestLog = InQuestLog

-- Прогресс задания из живого журнала: "3/7".
local function Progress(questId)
    local index = LogIndex()[questId]
    if not index then return nil end

    local collected, needed = 0, 1
    if (GetNumQuestLeaderBoards(index) or 0) > 0 then
        local text = GetQuestLogLeaderBoard(1, index)
        local c, n = tostring(text or ""):match("(%d+)%s*/%s*(%d+)")
        collected = tonumber(c) or 0
        needed = tonumber(n) or 1
    end

    local _, _, _, _, _, _, isComplete = GetQuestLogTitle(index)
    return collected, needed, (isComplete == 1)
end
ns.Progress = Progress

-- ------------------------------------------------------------- сбросы -----
local function NextDailyReset()
    local seconds = GetQuestResetTime and GetQuestResetTime() or 0
    if seconds and seconds > 60 and seconds < 86400 * 2 then
        return time() + seconds     -- время сервера, а не часы компьютера
    end
    return time() + 86400
end

local function NextWeeklyReset()
    local dailyReset = NextDailyReset()
    for i = 0, 7 do
        local moment = dailyReset + i * 86400
        if (tonumber(date("%w", moment)) + 1) == WEEKLY_RESET_WDAY then
            return moment
        end
    end
    return dailyReset + 7 * 86400
end

local function ResetFor(kind)
    return (kind == "weekly") and NextWeeklyReset() or NextDailyReset()
end
ns.ResetFor = ResetFor
ns.NextDailyReset = NextDailyReset
ns.NextWeeklyReset = NextWeeklyReset

function ns.FormatTime(seconds)
    if not seconds or seconds < 0 then seconds = 0 end
    local d = floor(seconds / 86400)
    local h = floor((seconds % 86400) / 3600)
    local m = floor((seconds % 3600) / 60)
    if d > 0 then return format("%dд %dч", d, h) end
    if h > 0 then return format("%dч %02dм", h, m) end
    return format("%dм", m)
end

-- ------------------------------------------------------- состояние сервера --
-- Список награждённых квестов - единственный надёжный источник для еженедельных.
-- Ежедневные ядро туда не кладёт, для них работает наблюдение за сдачей.
local completed = nil
local lastQuery = 0

local function Query(force)
    if not QueryQuestsCompleted then return end
    local now = GetTime()
    if (not force) and (now - lastQuery) < QUERY_THROTTLE then return end
    lastQuery = now
    pcall(QueryQuestsCompleted)
end
ns.Query = Query

function ns.ServerSaysDone(questId)
    return completed and completed[questId] or false
end

-- "done" | "inlog" | "elsewhere" | "available"
-- Единственный источник правды - отметка со сроком: срок считается от часов
-- сервера, а его список наград после сброса врёт.
function ns.KindState(kind)
    for id, quest in pairs(ns.QUESTS) do
        if quest.kind == kind and InQuestLog(id) then return "inlog" end
    end

    PurgeExpired(kind)
    if AccountDone()[kind] then return "done" end

    if #ns.OthersHolding(kind) > 0 then return "elsewhere" end
    return "available"
end

-- ------------------------------------------------------ срезы персонажей ---
-- "Ежедневное испытание рейда" -> "рейда"
local function ShortName(quest)
    local name = quest and quest.name or "?"
    return (name:gsub("^Ежедневное испытание ", ""):gsub("^Испытание ", ""))
end
ns.ShortName = ShortName

local function UpdateSnapshot()
    local me = UnitName("player")
    if not me then return end

    local mine = {}
    for id in pairs(ns.QUESTS) do
        local collected, needed, done = Progress(id)
        if collected then
            mine[id] = { c = collected, n = needed, done = done }
        end
    end

    Snapshots()[me] = next(mine) and mine or nil
end
ns.UpdateSnapshot = UpdateSnapshot

-- Кто из ДРУГИХ персонажей держит задание этой группы.
function ns.OthersHolding(kind)
    local me = UnitName("player")
    local held = {}
    for charName, entry in pairs(Snapshots()) do
        if charName ~= me and type(entry) == "table" then
            for id, info in pairs(entry) do
                local quest = ns.QUESTS[id]
                if quest and quest.kind == kind and type(info) == "table" then
                    held[#held + 1] = {
                        char = charName,
                        desc = ShortName(quest),
                        c = info.c or 0,
                        n = info.n or 1,
                        done = info.done,
                    }
                end
            end
        end
    end
    table.sort(held, function(a, b) return a.char < b.char end)
    return held
end

-- --------------------------------------------------------------- сдача ----
local function MarkDone(kind, questId, fromServer)
    if questId then StaleSet(kind)[questId] = nil end   -- выполнено по-настоящему
    AccountDone()[kind] = {
        expires = ResetFor(kind),
        by      = UnitName("player"),
        questId = questId,
        srv     = fromServer and true or false,
    }
    if ns.Refresh then ns.Refresh() end
end
ns.MarkDone = MarkDone

local pendingTurnIn = nil

local function NoteTurnIn(questTitle)
    if not questTitle then return end
    local title = Norm(questTitle)
    for id, quest in pairs(ns.QUESTS) do
        if Norm(quest.name) == title then
            MarkDone(quest.kind, id, false)
            Print(ns.KIND_LABEL[quest.kind] .. " задание сдано.")
            return
        end
    end
end

hooksecurefunc("GetQuestReward", function()
    if pendingTurnIn then
        NoteTurnIn(pendingTurnIn)
        pendingTurnIn = nil
    end
end)

-- ------------------------------------------------------- серверное меню ---
local pendingMenu = nil

local function FindOption(needle)
    local count = GetNumGossipOptions and GetNumGossipOptions() or 0
    if count == 0 then return nil end
    local options = { GetGossipOptions() }
    needle = Norm(needle)
    for i = 1, count do
        local text = options[(i - 1) * 2 + 1]
        if text and Norm(text):find(needle, 1, true) then return i end
    end
end

-- Документация клиента обрезает список возвратов, поэтому шаг массива выводим
-- из числа заданий, а не берём на веру.
local function FindActiveQuest(questName)
    if not (GetGossipActiveQuests and GetNumGossipActiveQuests) then return nil end
    local count = GetNumGossipActiveQuests() or 0
    if count == 0 then return nil end

    local list = { GetGossipActiveQuests() }
    local stride = floor(#list / count)
    if stride < 1 then return nil end

    questName = Norm(questName)
    for i = 1, count do
        local name = list[(i - 1) * stride + 1]
        if name and Norm(name):find(questName, 1, true) then return i end
    end
end

-- questName задаётся, когда надо открыть окно сдачи конкретного задания.
function ns.OpenMenu(kind, questName)
    if not SendChatMessage then return end
    pendingMenu = { kind = kind, step = 1, questName = questName, expires = GetTime() + 8 }
    SendChatMessage(MENU_COMMAND, "SAY")
end

local function HandleGossip()
    if not pendingMenu then return end
    if GetTime() > pendingMenu.expires then
        pendingMenu = nil
        return
    end

    local path = MENU_PATH[pendingMenu.kind] or MENU_PATH.daily
    local step = path[pendingMenu.step]

    if step then
        local index = FindOption(step)
        if index then
            pendingMenu.step = pendingMenu.step + 1
            pendingMenu.expires = GetTime() + 8
            SelectGossipOption(index)
            return
        end
    end

    local questName = pendingMenu.questName
    pendingMenu = nil

    if questName then
        local index = FindActiveQuest(questName)
        if index then
            SelectGossipActiveQuest(index)
            return
        end
    end
    -- Не нашли: окно остаётся открытым, выбирает игрок.
end

-- Задание из группы, которое сейчас в журнале. Нужно для клика по строке.
function ns.QuestInLog(kind)
    for id, quest in pairs(ns.QUESTS) do
        if quest.kind == kind and InQuestLog(id) then return id, quest end
    end
end

-- Есть ли то, что требует действия прямо сейчас.
function ns.Pending()
    for _, kind in ipairs(ns.KINDS) do
        local state = ns.KindState(kind)
        if state == "available" then return true, kind, "available" end
        if state == "inlog" then
            local id = ns.QuestInLog(kind)
            local _, _, done = ns.Progress(id)
            if done then return true, kind, "turnin" end
        end
    end
    return false
end

-- ------------------------------------------------------------- напоминание --
function ns.PlayAlert()
    local ok = pcall(PlaySoundFile, ALERT_SOUND)
    if not ok then
        -- Если свой файл почему-то не проигрался, берём стандартный.
        if not pcall(PlaySoundFile, "Sound\\Interface\\RaidWarning.wav") then
            pcall(PlaySound, "RaidWarning")
        end
    end
end

local function Announce()
    local pending = {}
    for _, kind in ipairs(ns.KINDS) do
        local state = ns.KindState(kind)
        if state == "available" then
            pending[#pending + 1] = ns.KIND_LABEL[kind] .. " задание можно взять"
        elseif state == "inlog" then
            local id = ns.QuestInLog(kind)
            local c, n, done = Progress(id)
            if done then
                pending[#pending + 1] = ns.KIND_LABEL[kind] .. " задание готово к сдаче"
            elseif c then
                pending[#pending + 1] = format("%s задание: %d/%d",
                    ns.KIND_LABEL[kind], c, n)
            end
        end
    end

    if #pending == 0 then return end
    for _, line in ipairs(pending) do Print(line) end

    if DB().sound then ns.PlayAlert() end
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "WoW Circle: есть задания",
            ChatTypeInfo["RAID_WARNING"])
    end
end
ns.Announce = Announce

-- ----------------------------------------------------------------- события --
local ev = CreateFrame("Frame")
ns.events = ev

local queryDelay, pollTimer, tickTimer = nil, 0, 0
local remindTimer, loginTimer = 0, nil

-- PLAYER_ENTERING_WORLD приходит на КАЖДОМ экране загрузки: вход в подземелье,
-- выход, портал, телепорт. Приветствие должно быть одно на сессию, иначе аддон
-- здоровается после каждой загрузки.
local greeted = false

ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("QUEST_QUERY_COMPLETE")
ev:RegisterEvent("QUEST_LOG_UPDATE")
ev:RegisterEvent("QUEST_COMPLETE")
ev:RegisterEvent("QUEST_FINISHED")
ev:RegisterEvent("GOSSIP_SHOW")

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        local db = DB()
        if db.shown == nil then db.shown = true end
        if db.remindMinutes == nil then db.remindMinutes = 0 end
        if db.sound == nil then db.sound = false end

        -- Значения по умолчанию поменялись уже после первых установок:
        -- напоминания выключены, вид - кнопка у миникарты. Применяем один раз,
        -- чтобы не переписывать то, что игрок выбрал сам потом.
        if not db.ver then
            db.ver = 2
            db.remindMinutes = 0
        end
        if db.ver < 7 then
            db.ver = 7
            db.done = {}
            db.stale = {}       -- сменился формат: было число, стало множество
        end
        if db.ver < 6 then
            db.ver = 6
            -- Отметки могли быть воскрешены ответом сервера уже после сброса,
            -- с сроком на следующий период. Сбрасываем один раз.
            db.done = {}
            db.stale = {}
        end
        if db.ver < 5 then
            db.ver = 5
            -- Старые отметки лежали одной кучей на весь аккаунт, без реалма.
            -- Определить задним числом, к какому реалму они относились, нельзя,
            -- поэтому сбрасываем: ежедневные протухнут за сутки, недельные
            -- подтвердит сервер.
            db.done = {}
            db.chars = {}
        end
        if db.ver < 4 then
            db.ver = 4
            db.sound = false
        end
        if db.ver < 3 then
            db.ver = 3
            -- Кнопка миникарты перестала быть одним из видов и теперь есть
            -- всегда, поэтому старое значение style больше не имеет смысла.
            if db.style == "minimap" or db.style == nil then db.style = "none" end
        end

        ns.Build()

    elseif event == "GOSSIP_SHOW" then
        HandleGossip()

    elseif event == "PLAYER_ENTERING_WORLD" then
        logIndexDirty = true
        queryDelay = 5
        UpdateSnapshot()
        if not greeted then
            greeted = true
            loginTimer = 0
        end

    elseif event == "QUEST_QUERY_COMPLETE" then
        if not GetQuestsCompleted then return end
        local t = {}
        local ok, r = pcall(GetQuestsCompleted, t)
        if not ok then return end
        if type(r) == "table" then t = r end
        completed = t

        -- Сверяем аккаунтную отметку с ответом сервера.
        local me = UnitName("player")
        local done = AccountDone()
        for _, kind in ipairs(ns.KINDS) do
            PurgeExpired(kind)

            -- Сервер отдаёт ВСЕ когда-либо награждённые квесты, включая тот, по
            -- которому отметка уже протухла. Берём любой другой: именно он
            -- означает настоящую сдачу в этом периоде.
            local stale = StaleSet(kind)
            local finishedId, anyReported = nil, false
            for id, quest in pairs(ns.QUESTS) do
                if quest.kind == kind and t[id] then
                    anyReported = true
                    if not stale[id] then finishedId = id break end
                end
            end

            local record = done[kind]
            if finishedId then
                MarkDone(kind, finishedId, true)
            elseif not anyReported then
                -- Сервер не помнит по этой группе вообще ничего.
                for id in pairs(stale) do stale[id] = nil end
                if record and record.srv and record.by == me then
                    -- Отметку, поставленную по факту сдачи, так снимать нельзя:
                    -- про ежедневные сервер молчит всегда.
                    done[kind] = nil
                end
            end
        end
        if ns.Refresh then ns.Refresh() end

    elseif event == "QUEST_COMPLETE" then
        pendingTurnIn = GetTitleText and GetTitleText() or nil

    elseif event == "QUEST_FINISHED" then
        queryDelay = 3

    elseif event == "QUEST_LOG_UPDATE" then
        logIndexDirty = true
        UpdateSnapshot()
        Query()
        if ns.Refresh then ns.Refresh() end
    end
end)

ev:SetScript("OnUpdate", function(_, elapsed)
    if queryDelay then
        queryDelay = queryDelay - elapsed
        if queryDelay <= 0 then queryDelay = nil; Query(true) end
    end

    pollTimer = pollTimer + elapsed
    if pollTimer >= QUERY_INTERVAL then
        pollTimer = 0
        Query()
    end

    tickTimer = tickTimer + elapsed
    if tickTimer >= 1 then
        tickTimer = 0
        if ns.Refresh then ns.Refresh() end
    end

    if loginTimer then
        loginTimer = loginTimer + elapsed
        if loginTimer >= 8 then
            loginTimer = nil
            Announce()
        end
    end

    local minutes = DB().remindMinutes or 0
    if minutes > 0 and not loginTimer then
        remindTimer = remindTimer + elapsed
        if remindTimer >= minutes * 60 then
            remindTimer = 0
            if not UnitAffectingCombat("player") then Announce() end
        end
    end
end)

-- ------------------------------------------------------------- команды -----
-- Не занимаем /circle: его регистрирует версия для Questie, и галочка в её
-- настройках этого не меняет - файл всё равно загружается.
SLASH_CIRCLEDW1 = "/cdw"
SLASH_CIRCLEDW2 = "/circledw"
SlashCmdList["CIRCLEDW"] = function(msg)
    local arg = strlower(strtrim(msg or ""))

    if arg == "" then
        DB().shown = not DB().shown
        if ns.Refresh then ns.Refresh() end
        return
    end

    if arg == "daily" or arg == "weekly" then
        ns.OpenMenu(arg)
        return
    end

    if arg == "take" then
        for _, kind in ipairs(ns.KINDS) do
            if ns.KindState(kind) == "available" then
                ns.OpenMenu(kind)
                return
            end
        end
        Print("нечего брать - всё либо в журнале, либо уже выполнено")
        return
    end

    local action, kind = arg:match("^(%a+)%s+(%a+)$")
    if (action == "done" or action == "undone") and (kind == "daily" or kind == "weekly") then
        if action == "done" then
            MarkDone(kind, nil, false)
            Print(ns.KIND_LABEL[kind] .. ": отмечено выполненным до сброса")
        else
            AccountDone()[kind] = nil
            Print(ns.KIND_LABEL[kind] .. ": отметка снята")
            if ns.Refresh then ns.Refresh() end
        end
        return
    end

    if arg == "minimap" then
        ns.DB().minimap = not ns.MinimapShown()
        Print("кнопка у миникарты: " .. (ns.MinimapShown() and "показана" or "скрыта"))
        ns.Refresh()
        return
    end

    local style = arg:match("^style%s+(%a+)$")
    if style == "badge" or style == "none" or style == "list" then
        ns.DB().style = style
        Print("вид: " .. style)
        ns.Refresh()
        return
    end

    local minutes = arg:match("^remind%s+(%d+)$")
    if minutes then
        DB().remindMinutes = tonumber(minutes)
        Print("напоминать раз в " .. minutes .. " мин (0 - выключить)")
        return
    end

    if arg == "testsound" then
        ns.PlayAlert()
        Print("проиграл звук напоминания")
        return
    end

    if arg == "sound" then
        DB().sound = not DB().sound
        Print("звук: " .. (DB().sound and "включён" or "выключён"))
        return
    end

    if arg == "lock" then
        DB().locked = not DB().locked
        Print("окно " .. (DB().locked and "закреплено" or "можно двигать"))
        return
    end

    if arg == "status" then
        for _, kind in ipairs(ns.KINDS) do
            local state = ns.KindState(kind)
            Print(ns.KIND_LABEL[kind] .. ": " .. state)
            local record = AccountDone()[kind]
            if record and record.expires and record.expires > time() then
                Print(format("   сдал %s (%s), сброс через %s",
                    tostring(record.by),
                    record.srv and "подтверждено сервером" or "замечено при сдаче",
                    ns.FormatTime(record.expires - time())))
            end
            for _, held in ipairs(ns.OthersHolding(kind)) do
                Print(format("   %s - %s: %d/%d%s", held.char, held.desc,
                    held.c, held.n, held.done and " (готово к сдаче)" or ""))
            end
        end
        Print(format("сброс: ежедневный %s, недельный %s",
            date("%d.%m %H:%M", NextDailyReset()),
            date("%d.%m %H:%M", NextWeeklyReset())))
        return
    end

    Print("команды: |cff00ff00/cdw|r показать, |cff00ff00status|r, |cff00ff00take|r, |cff00ff00daily|r, |cff00ff00weekly|r")
    Print("вид: |cff00ff00/cdw style none|badge|list|r, кнопка: |cff00ff00/cdw minimap|r")
    Print("ещё: |cff00ff00done daily|r, |cff00ff00undone weekly|r, |cff00ff00remind 30|r, |cff00ff00sound|r, |cff00ff00testsound|r, |cff00ff00lock|r")
end
