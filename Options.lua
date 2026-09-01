local ADDON, ns = ...

-- Панель в стандартных настройках игры: Меню -> Интерфейс -> Аддоны.

local STYLES = {
    { key = "badge",   name = "Значок",
      desc = "Появляется, только когда есть незакрытое задание. Пропал - значит всё сделано." },
    { key = "minimap", name = "Кнопка у миникарты",
      desc = "Видна всегда, состояние показывает значком. Перетаскивается по кругу." },
    { key = "list",    name = "Список",
      desc = "Строки в стиле трекера Questie: что за задание и какой прогресс." },
}

local function BuildOptions()
    local panel = CreateFrame("Frame", "CircleDailyWeeklyOptions", UIParent)
    panel.name = "WoW Circle: daily & weekly"

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("WoW Circle: ежедневные и еженедельные")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    subtitle:SetWidth(400)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Как показывать состояние заданий.")

    local checks = {}
    local y = -70

    for _, style in ipairs(STYLES) do
        local check = CreateFrame("CheckButton", "CircleDWStyle" .. style.key,
                                  panel, "InterfaceOptionsCheckButtonTemplate")
        check:SetPoint("TOPLEFT", 20, y)
        _G[check:GetName() .. "Text"]:SetText(style.name)
        check.tooltipText = style.name
        check.tooltipRequirement = style.desc

        local hint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        hint:SetPoint("TOPLEFT", check, "BOTTOMLEFT", 26, 2)
        hint:SetWidth(420)
        hint:SetJustifyH("LEFT")
        hint:SetText(style.desc)

        -- Ведут себя как радиокнопки: вид всегда ровно один.
        check:SetScript("OnClick", function(self)
            ns.DB().style = style.key
            for key, other in pairs(checks) do
                other:SetChecked(key == style.key)
            end
            self:SetChecked(true)
            ns.Refresh()
        end)

        checks[style.key] = check
        y = y - 46
    end

    local sound = CreateFrame("CheckButton", "CircleDWSound", panel,
                              "InterfaceOptionsCheckButtonTemplate")
    sound:SetPoint("TOPLEFT", 20, y - 10)
    _G["CircleDWSoundText"]:SetText("Звук напоминания")
    sound:SetScript("OnClick", function(self)
        ns.DB().sound = self:GetChecked() and true or false
    end)

    local slider = CreateFrame("Slider", "CircleDWRemind", panel,
                               "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 24, y - 60)
    slider:SetWidth(260)
    slider:SetMinMaxValues(0, 120)
    slider:SetValueStep(5)
    _G["CircleDWRemindLow"]:SetText("выкл")
    _G["CircleDWRemindHigh"]:SetText("120 мин")
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / 5 + 0.5) * 5
        ns.DB().remindMinutes = value
        _G["CircleDWRemindText"]:SetText(value == 0
            and "Напоминать: выключено"
            or ("Напоминать раз в " .. value .. " мин"))
    end)

    -- Значения подставляем при каждом открытии панели: настройки могли
    -- измениться слеш-командой.
    panel.refresh = function()
        local db = ns.DB()
        for key, check in pairs(checks) do
            check:SetChecked(key == ns.Style())
        end
        sound:SetChecked(db.sound ~= false)
        slider:SetValue(db.remindMinutes or 30)
    end

    panel:SetScript("OnShow", panel.refresh)

    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end

    ns.optionsPanel = panel
end

table.insert(ns.builders, BuildOptions)
