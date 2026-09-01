local ADDON, ns = ...

-- Окно повторяет вид трекера Questie: прозрачный фон, та же типографика и
-- отступы. Значения ниже взяты из самого Questie, а не подобраны на глаз:
-- шрифт Friz Quadrata, размеры 12/10/10, отступы 14/36/46, цвета заголовка
-- зоны, повторяемого задания и строки цели.

local FONT = "Fonts\\FRIZQT__.TTF"

local SIZE_ZONE, SIZE_QUEST, SIZE_OBJECTIVE = 12, 10, 10
local MARGIN_ZONE, MARGIN_QUEST, MARGIN_OBJECTIVE = 14, 36, 46
local MARGIN_RIGHT = 30

local COLOR_ZONE      = "|cFFC0C0C0"    -- заголовок зоны
local COLOR_REPEAT    = "|cFF21CCE7"    -- повторяемое задание
local COLOR_OBJECTIVE = "|cFFEEEEEE"    -- строка цели

local ZONE_TITLE = "WoW Circle Ежедневное и еженедельное"

local ICON_AVAILABLE  = "Interface\\GossipFrame\\AvailableQuestIcon"
local ICON_INCOMPLETE = "Interface\\GossipFrame\\IncompleteQuestIcon"
local ICON_COMPLETE   = "Interface\\GossipFrame\\ActiveQuestIcon"

local frame, lines, lineCount
local RenderList          -- объявлено заранее: BuildList вызывает её ниже по файлу

-- --------------------------------------------------------------- строки ---
local function GetLine(index)
    if lines[index] then return lines[index] end

    local line = CreateFrame("Button", nil, frame)
    line:SetHeight(SIZE_ZONE + 2)
    line:RegisterForClicks("LeftButtonUp")

    line.icon = line:CreateTexture(nil, "ARTWORK")
    line.icon:SetWidth(SIZE_QUEST + 4)
    line.icon:SetHeight(SIZE_QUEST + 4)

    line.label = line:CreateFontString(nil, "OVERLAY")
    line.label:SetJustifyH("LEFT")

    line.highlight = line:CreateTexture(nil, "BACKGROUND")
    line.highlight:SetAllPoints(line)
    line.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    line.highlight:SetBlendMode("ADD")
    line.highlight:SetAlpha(0.25)
    line.highlight:Hide()

    line:SetScript("OnEnter", function(self)
        if self.kind then self.highlight:Show() end
    end)
    line:SetScript("OnLeave", function(self) self.highlight:Hide() end)

    -- У этих заданий нет NPC: и взять, и сдать можно только через меню.
    line:SetScript("OnClick", function(self)
        if not self.kind then return end
        if ns.KindState(self.kind) == "done" then
            ns.Print(ns.KIND_LABEL[self.kind] .. " уже выполнено в этом периоде.")
            return
        end
        local id, quest = ns.QuestInLog(self.kind)
        local ready = false
        if id then
            local _, _, isDone = ns.Progress(id)
            ready = isDone and true or false
        end
        ns.OpenMenu(self.kind, (ready and quest) and quest.name or nil)
    end)

    lines[index] = line
    return line
end

local function AddLine(text, size, margin, icon, kind)
    lineCount = lineCount + 1
    local line = GetLine(lineCount)

    line.kind = kind
    line.label:SetFont(FONT, size, "")
    line.label:SetText(text)

    if icon then
        line.icon:SetTexture(icon)
        line.icon:ClearAllPoints()
        line.icon:SetPoint("LEFT", line, "LEFT", margin - SIZE_QUEST - 6, 0)
        line.icon:Show()
    else
        line.icon:Hide()
    end

    line.label:ClearAllPoints()
    line.label:SetPoint("LEFT", line, "LEFT", margin, 0)
    line:SetHeight(size + 4)
    line:Show()

    return line
end

-- ---------------------------------------------------------------- сборка --
local function BuildList()
    if frame then return end

    -- Прозрачный фон, как у трекера Questie: рамки нет вообще.
    frame = CreateFrame("Frame", "CircleDailyWeeklyFrame", UIParent)
    frame:SetWidth(220)
    frame:SetHeight(40)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not ns.DB().locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.DB().point = { point, relPoint, x, y }
    end)

    lines = {}

    local point = ns.DB().point or {}
    frame:SetPoint(point[1] or "TOPRIGHT", UIParent, point[2] or "TOPRIGHT",
                   point[3] or -60, point[4] or -220)

    RenderList()
end

-- ------------------------------------------------------------- обновление --
function RenderList()
    if not frame then return end

    for _, line in ipairs(lines) do
        line:Hide()
        line.kind = nil
    end
    lineCount = 0

    if ns.Style() ~= "list" or not ns.DB().shown then
        frame:Hide()
        return
    end

    -- Собираем содержимое: только то, что требует действия. Выполненное в этом
    -- периоде не показываем - как и в версии для Questie.
    local body = {}
    for _, kind in ipairs(ns.KINDS) do
        local state = ns.KindState(kind)
        if state ~= "done" then
            local id, quest = ns.QuestInLog(kind)

            if id then
                -- Задание в журнале: показываем его настоящее имя и прогресс,
                -- ровно как трекер Questie показывает обычный квест.
                local collected, needed, done = ns.Progress(id)
                body[#body + 1] = {
                    text = COLOR_REPEAT .. "[80] " .. quest.name .. "|r",
                    size = SIZE_QUEST, margin = MARGIN_QUEST, kind = kind,
                    icon = done and ICON_COMPLETE or ICON_INCOMPLETE,
                }
                if collected then
                    body[#body + 1] = {
                        text = ("%s- %s: %d/%d|r"):format(COLOR_OBJECTIVE,
                            ns.ShortName(quest), collected, needed),
                        size = SIZE_OBJECTIVE, margin = MARGIN_OBJECTIVE,
                    }
                end
            else
                body[#body + 1] = {
                    text = COLOR_REPEAT .. "[80] " .. ns.KIND_LABEL[kind] .. " испытание|r",
                    size = SIZE_QUEST, margin = MARGIN_QUEST, kind = kind,
                    icon = ICON_AVAILABLE,
                }
                for _, held in ipairs(ns.OthersHolding(kind)) do
                    body[#body + 1] = {
                        text = ("%s- %s: %s %d/%d%s|r"):format(COLOR_OBJECTIVE,
                            held.char, held.desc, held.c, held.n,
                            held.done and " (готово)" or ""),
                        size = SIZE_OBJECTIVE, margin = MARGIN_OBJECTIVE,
                    }
                end
            end
        end
    end

    if #body == 0 then
        frame:Hide()
        return
    end
    frame:Show()

    local widest = 0
    local y = 4

    local zone = AddLine(COLOR_ZONE .. ZONE_TITLE .. "|r", SIZE_ZONE, MARGIN_ZONE)
    zone:ClearAllPoints()
    zone:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -y)
    widest = math.max(widest, zone.label:GetStringWidth() + MARGIN_ZONE)
    y = y + SIZE_ZONE + 4

    for _, item in ipairs(body) do
        local line = AddLine(item.text, item.size, item.margin, item.icon, item.kind)
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -y)
        widest = math.max(widest, line.label:GetStringWidth() + item.margin)
        y = y + item.size + 4
    end

    for _, line in ipairs(lines) do
        line:SetWidth(widest + MARGIN_RIGHT)
    end

    frame:SetWidth(widest + MARGIN_RIGHT)
    frame:SetHeight(y + 4)
end

table.insert(ns.builders, BuildList)
table.insert(ns.renderers, RenderList)
