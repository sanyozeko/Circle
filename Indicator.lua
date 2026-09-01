local ADDON, ns = ...

-- Два способа показать состояние, кроме списка:
--
--   badge   - значок, который есть на экране ТОЛЬКО пока есть незакрытое дело.
--             Ничего читать не надо: пропал - значит всё сделано.
--   minimap - кнопка у миникарты, видна всегда, состояние передаётся значком.
--
-- Оба кликабельны и показывают полное состояние в подсказке.

local ICON_AVAILABLE = "Interface\\GossipFrame\\AvailableQuestIcon"
local ICON_TURNIN    = "Interface\\GossipFrame\\ActiveQuestIcon"
local ICON_IDLE      = "Interface\\GossipFrame\\IncompleteQuestIcon"

local MINIMAP_RADIUS = 80

local badge, minimapButton

-- ---------------------------------------------------------------- подсказка --
local function ShowTooltip(owner, anchor)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_LEFT")
    GameTooltip:AddLine("WoW Circle", 1, 1, 1)

    for _, kind in ipairs(ns.KINDS) do
        local state = ns.KindState(kind)
        local label = ns.KIND_LABEL[kind]

        if state == "done" then
            local record = ns.AccountDone()[kind]
            local left = record and record.expires and (record.expires - time())
            GameTooltip:AddDoubleLine(label,
                left and left > 0 and ("сброс через " .. ns.FormatTime(left)) or "выполнено",
                0.6, 0.6, 0.6, 0.6, 0.6, 0.6)

        elseif state == "inlog" then
            local id, quest = ns.QuestInLog(kind)
            local collected, needed, done = ns.Progress(id)
            if done then
                GameTooltip:AddDoubleLine(label, "готово к сдаче", 1, 1, 1, 0.1, 1, 0.1)
            else
                GameTooltip:AddDoubleLine(label,
                    ("%d/%d"):format(collected or 0, needed or 1), 1, 1, 1, 1, 0.82, 0)
            end
            GameTooltip:AddLine("   " .. quest.name, 0.6, 0.6, 0.6)

        elseif state == "elsewhere" then
            GameTooltip:AddDoubleLine(label, "взято на другом", 1, 1, 1, 1, 0.82, 0)
            for _, held in ipairs(ns.OthersHolding(kind)) do
                GameTooltip:AddLine(("   %s - %s: %d/%d%s"):format(held.char,
                    held.desc, held.c, held.n, held.done and " готово" or ""),
                    0.6, 0.6, 0.6)
            end

        else
            GameTooltip:AddDoubleLine(label, "можно взять", 1, 1, 1, 0.1, 1, 0.1)
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("ЛКМ - открыть меню заданий", 0.4, 0.8, 1)
    GameTooltip:AddLine("Перетаскивание - переместить", 0.4, 0.8, 1)
    GameTooltip:Show()
end

-- Что делать по клику: берём первое, что требует действия.
local function ActOnClick()
    local pending, kind = ns.Pending()
    if not pending then
        kind = ns.KINDS[1]
        for _, k in ipairs(ns.KINDS) do
            if ns.KindState(k) ~= "done" then kind = k break end
        end
    end

    if ns.KindState(kind) == "done" then
        ns.Print("на сегодня всё закрыто.")
        return
    end

    local id, quest = ns.QuestInLog(kind)
    local ready = false
    if id then
        local _, _, isDone = ns.Progress(id)
        ready = isDone and true or false
    end
    ns.OpenMenu(kind, (ready and quest) and quest.name or nil)
end

-- Какой значок показывать: что-то доступно / готово к сдаче / всё тихо.
local function CurrentIcon()
    local pending, _, reason = ns.Pending()
    if not pending then return ICON_IDLE, false end
    return (reason == "turnin") and ICON_TURNIN or ICON_AVAILABLE, true
end

-- ------------------------------------------------------------------ значок --
local function BuildBadge()
    if badge then return end

    badge = CreateFrame("Button", "CircleDailyWeeklyBadge", UIParent)
    badge:SetWidth(32)
    badge:SetHeight(32)
    badge:SetClampedToScreen(true)
    badge:SetMovable(true)
    badge:EnableMouse(true)
    badge:RegisterForDrag("LeftButton")
    badge:RegisterForClicks("LeftButtonUp")

    badge.icon = badge:CreateTexture(nil, "ARTWORK")
    badge.icon:SetAllPoints(badge)

    badge:SetScript("OnDragStart", function(self)
        if not ns.DB().locked then self:StartMoving() end
    end)
    badge:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.DB().badgePoint = { point, relPoint, x, y }
    end)
    badge:SetScript("OnEnter", function(self) ShowTooltip(self) end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    badge:SetScript("OnClick", ActOnClick)

    -- Пульсация: значок должен ловиться боковым зрением, но не мигать резко.
    badge:SetScript("OnUpdate", function(self)
        self.icon:SetAlpha(0.65 + 0.35 * math.abs(math.sin(GetTime() * 2)))
    end)

    local point = ns.DB().badgePoint or {}
    badge:SetPoint(point[1] or "CENTER", UIParent, point[2] or "CENTER",
                   point[3] or 250, point[4] or 120)
    badge:Hide()
end

local function RenderBadge()
    if not badge then return end

    if ns.Style() ~= "badge" then
        badge:Hide()
        return
    end

    local icon, pending = CurrentIcon()
    if not pending then
        badge:Hide()        -- нечего делать - значка на экране нет вообще
        return
    end

    badge.icon:SetTexture(icon)
    badge:Show()
end

-- ------------------------------------------------------ кнопка у миникарты --
local function PlaceMinimapButton()
    local angle = ns.DB().minimapAngle or 200
    local x = MINIMAP_RADIUS * math.cos(math.rad(angle))
    local y = MINIMAP_RADIUS * math.sin(math.rad(angle))
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function BuildMinimapButton()
    if minimapButton or not Minimap then return end

    minimapButton = CreateFrame("Button", "CircleDailyWeeklyMinimapButton", Minimap)
    minimapButton:SetWidth(31)
    minimapButton:SetHeight(31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(8)
    minimapButton:RegisterForClicks("LeftButtonUp")
    minimapButton:RegisterForDrag("LeftButton")

    minimapButton.icon = minimapButton:CreateTexture(nil, "BACKGROUND")
    minimapButton.icon:SetWidth(19)
    minimapButton.icon:SetHeight(19)
    minimapButton.icon:SetPoint("CENTER", minimapButton, "CENTER", -1, 1)

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 0, 0)

    -- Перетаскивание по кругу: считаем угол от центра миникарты к курсору.
    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale
            ns.DB().minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
            PlaceMinimapButton()
        end)
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    minimapButton:SetScript("OnEnter", function(self) ShowTooltip(self, "ANCHOR_LEFT") end)
    minimapButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    minimapButton:SetScript("OnClick", ActOnClick)

    PlaceMinimapButton()
    minimapButton:Hide()
end

local function RenderMinimapButton()
    if not minimapButton then return end

    if ns.Style() ~= "minimap" then
        minimapButton:Hide()
        return
    end

    local icon, pending = CurrentIcon()
    minimapButton.icon:SetTexture(icon)
    minimapButton.icon:SetDesaturated(not pending)
    minimapButton.icon:SetAlpha(pending and 1 or 0.5)
    minimapButton:Show()
end

table.insert(ns.builders, BuildBadge)
table.insert(ns.builders, BuildMinimapButton)
table.insert(ns.renderers, RenderBadge)
table.insert(ns.renderers, RenderMinimapButton)
