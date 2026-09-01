local ADDON, ns = ...

-- Небольшое окно со списком: по строке на группу заданий, под ней - персонажи,
-- у которых задание лежит в журнале.

local WIDTH, PAD, ROW_H, SUB_H = 250, 12, 16, 13

local COLOR = {
    available = { 0.20, 1.00, 0.20 },   -- можно взять
    inlog     = { 1.00, 0.82, 0.00 },   -- взято этим персонажем
    elsewhere = { 1.00, 0.82, 0.00 },   -- взято другим
    done      = { 0.45, 0.45, 0.45 },   -- выполнено
}

local BACKDROP = {
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile     = true, tileSize = 32, edgeSize = 16,
    insets   = { left = 5, right = 5, top = 5, bottom = 5 },
}

local frame, rows

local function StateText(kind)
    local state = ns.KindState(kind)

    if state == "done" then
        local record = ns.AccountDone()[kind]
        local left = record and record.expires and (record.expires - time())
        if left and left > 0 then
            return "выполнено · " .. ns.FormatTime(left), state
        end
        return "выполнено", state
    end

    if state == "inlog" then
        local id = ns.QuestInLog(kind)
        local c, n, done = ns.Progress(id)
        if done then return "готово к сдаче", state end
        if c then return ("взято · %d/%d"):format(c, n), state end
        return "взято", state
    end

    if state == "elsewhere" then return "взято на другом", state end
    return "можно взять", state
end

local function SavePoint()
    local point, _, relPoint, x, y = frame:GetPoint()
    ns.DB().point = { point, relPoint, x, y }
end

function ns.BuildUI()
    if frame then return end

    frame = CreateFrame("Frame", "CircleDailyWeeklyFrame", UIParent)
    frame:SetWidth(WIDTH)
    frame:SetHeight(90)
    frame:SetBackdrop(BACKDROP)
    frame:SetBackdropColor(0, 0, 0, 0.85)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not ns.DB().locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePoint()
    end)

    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -10)
    frame.title:SetText("WoW Circle")

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetWidth(24)
    frame.close:SetHeight(24)
    frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    frame.close:SetScript("OnClick", function()
        ns.DB().shown = false
        ns.Refresh()
    end)

    rows = {}
    for i, kind in ipairs(ns.KINDS) do
        local row = CreateFrame("Button", nil, frame)
        row.kind = kind
        row:SetWidth(WIDTH - PAD * 2)
        row:SetHeight(ROW_H)
        row:RegisterForClicks("LeftButtonUp")

        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetText(ns.KIND_LABEL[kind])

        row.state = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.state:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.state:SetJustifyH("RIGHT")

        row.highlight = row:CreateTexture(nil, "BACKGROUND")
        row.highlight:SetAllPoints(row)
        row.highlight:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
        row.highlight:SetBlendMode("ADD")
        row.highlight:SetAlpha(0.25)
        row.highlight:Hide()

        row:SetScript("OnEnter", function(self) self.highlight:Show() end)
        row:SetScript("OnLeave", function(self) self.highlight:Hide() end)

        -- У этих заданий нет NPC: и взять, и сдать можно только через меню.
        row:SetScript("OnClick", function(self)
            local state = ns.KindState(self.kind)
            if state == "done" then
                ns.Print(ns.KIND_LABEL[self.kind] .. " уже выполнено в этом периоде.")
                return
            end
            -- Осторожно: "id and ns.Progress(id)" срезало бы результат до
            -- одного значения, и done всегда был бы nil.
            local id, quest = ns.QuestInLog(self.kind)
            local ready = false
            if id then
                local _, _, isDone = ns.Progress(id)
                ready = isDone and true or false
            end
            ns.OpenMenu(self.kind, (ready and quest) and quest.name or nil)
        end)

        -- Подстроки: у кого задание лежит.
        row.subs = {}
        for j = 1, 4 do
            local sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            sub:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 8, -(j - 1) * SUB_H - 1)
            sub:SetJustifyH("LEFT")
            sub:Hide()
            row.subs[j] = sub
        end

        rows[i] = row
    end

    local point = ns.DB().point or {}
    frame:SetPoint(point[1] or "CENTER", UIParent, point[2] or "CENTER",
                   point[3] or 300, point[4] or 150)

    ns.Refresh()
end

function ns.Refresh()
    if not frame then return end

    if not ns.DB().shown then
        frame:Hide()
        return
    end
    frame:Show()

    local y = 30
    for _, row in ipairs(rows) do
        local text, state = StateText(row.kind)
        local c = COLOR[state]

        row.state:SetText(text)
        row.state:SetTextColor(c[1], c[2], c[3])
        row.label:SetTextColor(c[1], c[2], c[3])

        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
        y = y + ROW_H

        local shown = 0
        for _, sub in ipairs(row.subs) do sub:Hide() end
        for _, held in ipairs(ns.OthersHolding(row.kind)) do
            shown = shown + 1
            local sub = row.subs[shown]
            if not sub then break end
            sub:SetText(("%s - %s: %d/%d%s"):format(held.char, held.desc,
                held.c, held.n, held.done and " готово" or ""))
            sub:Show()
            y = y + SUB_H
        end
    end

    frame:SetHeight(y + 10)
end
