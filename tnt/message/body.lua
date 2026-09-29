--- Тело сообщения: простые данные в пределах, которые запишет любой кодек.
---
--- **Простые данные** — `nil`, логика, конечное число, строка и таблицы
--- из них с ключами-строками и целыми ключами-числами. Такое тело одинаково
--- ложится и в msgpack кортежа, и в JSON брокера, и обработчик на любой
--- очереди получает то же самое. cdata (`int64`, `decimal`, `uuid`,
--- `datetime`) в JSON теряет род, функция не ложится никуда, а NaN
--- и бесконечность JSON пишет словами, которых обратно не прочесть.
---
--- **Вложенность — не глубже `MAX_DEPTH` таблиц.** Кодеки `msgpack` и `json`
--- отказывают на 129-й таблице, а очередь кладёт тело глубже, чем его
--- видит вызывающий: в конверт, а конверт — в кортеж. Сотня оставляет
--- этому запас. Без предела тело, которое кодек не запишет, отказывало бы
--- позже и не по договору: отказом «сообщение ушло» у очереди в спейсе,
--- исключением из глубины пакета у брокера.
---
--- **Значений — не больше `MAX_VALUES`, и каждая ссылка считается так, как
--- её запишет кодек.** Таблица, положенная в две ветки, пишется дважды,
--- а положенная в две ветки на каждом из двадцати уровней — миллион раз,
--- двадцатью мегабайтами. Счёт ссылок, а не таблиц, держит обход такого
--- тела конечным и быстрым: отказ приходит на первом значении сверх
--- предела, сколько бы копий кодек ни собрался написать.
---
--- **Обход — списком, а не рекурсией**: глубину тела задаёт приложение, и
--- рекурсивный обход упирался бы в стек Lua там, где обход списком просто
--- просматривает дальше. На пути помнятся только таблицы от корня до той,
--- что сейчас раскрывается: таблица, лежащая на своём же пути, — кольцо,
--- а та же таблица в соседних ветках — обычное дело.

local Module = {}

--- Сколько таблиц тело вкладывает друг в друга самое большее; корень —
--- первая.
Module.MAX_DEPTH = 100

--- Сколько значений тело несёт самое большее: корень, каждое значение
--- в каждой таблице и каждая ссылка на таблицу — по разу.
Module.MAX_VALUES = 10000

--- Роды, которые годятся телом как есть; число проверяется отдельно.
---@type table<string, boolean|nil>
local PLAIN = { ['nil'] = true, boolean = true, string = true }

--- Роды ключей таблицы, которые запишут оба кодека.
---@type table<string, boolean|nil>
local KEYS = { string = true, number = true }

--- Чем значение, которое не таблица, не годится телом; `nil` — годится.
---
--- Место значения сюда не приходит: путь собирается строкой только
--- для отказа, а годное тело в десять тысяч значений собирало бы столько же
--- строк впустую.
---@param value any
---@return string|nil
local function unfit(value)
    local kind = type(value)

    if PLAIN[kind] then
        return nil
    end

    if kind ~= 'number' then
        return ('простые данные, а не %s'):format(kind)
    end

    -- NaN не равен сам себе.
    if value ~= value or math.abs(value) == math.huge then
        return ('конечное число, а не %s'):format(tostring(value))
    end

    return nil
end

---@class TntMessageBodyStep Таблица тела, которая ждёт раскрытия
---@field value table Сама таблица
---@field path string Где она лежит, для текста отказа
---@field depth integer Сколько таблиц от корня до неё, её считая

---@class TntMessageBodyWalk Обход тела
---@field pending table[] Таблицы, ждущие раскрытия, и отметки ухода с пути
---@field inside table<any, boolean> Таблицы на пути от корня
---@field counted integer Сколько значений уже увидено

--- Раскрывает одну таблицу тела: ключи, значения, таблицы на очередь.
---
--- Значение считается и проверяется в миг, когда его увидели, а таблица
--- ложится в список раскрытия: так список не бывает длиннее предела
--- значений, как бы широка ни была одна таблица.
---@param walk TntMessageBodyWalk
---@param step TntMessageBodyStep
---@return string|nil complaint
local function open(walk, step)
    -- Глубина детей, а не своя: сверка с пределом по ней отличает «ровно
    -- сто» от «больше ста», своя же глубина предела никогда не превышает.
    local depth = step.depth + 1

    for name, item in pairs(step.value) do
        local named = type(name)

        if not KEYS[named] then
            return ('%s: ключ — строка или число, а не %s'):format(step.path, named)
        end

        -- Дробный ключ JSON не пишет вовсе и бросает, а msgpack пишет: тело
        -- легло бы в очередь в спейсе и упало бы у брокера. У бесконечности
        -- остаток от деления на единицу — тоже не ноль.
        if named == 'number' and name % 1 ~= 0 then
            return ('%s: ключ-число — целое, а не %s'):format(step.path, tostring(name))
        end

        walk.counted = walk.counted + 1

        if walk.counted > Module.MAX_VALUES then
            return ('тело — не больше %d значений'):format(Module.MAX_VALUES)
        end

        if type(item) ~= 'table' then
            local wrong = unfit(item)

            if wrong ~= nil then
                return ('%s.%s — %s'):format(step.path, name, wrong)
            end
        elseif walk.inside[item] then
            return ('%s.%s — кольцо: таблица лежит сама в себе'):format(step.path, name)
        elseif depth > Module.MAX_DEPTH then
            return ('тело — вложенность глубже %d таблиц'):format(Module.MAX_DEPTH)
        else
            local path = ('%s.%s'):format(step.path, name)

            table.insert(walk.pending, { value = item, path = path, depth = depth })
        end
    end

    return nil
end

--- Чем тело не годится; `nil` — годится.
---
--- Отметка `leaving` снимает таблицу с пути, когда пройдены все её ветки:
--- она ложится в список прямо под детей своей таблицы и выходит из него
--- после них.
---@param body any
---@return string|nil
function Module.explain(body)
    if type(body) ~= 'table' then
        local wrong = unfit(body)

        return wrong and 'тело — ' .. wrong
    end

    local inside = {}

    ---@type TntMessageBodyWalk
    local walk = { pending = { { value = body, path = 'тело', depth = 1 } }, inside = inside, counted = 1 }

    while #walk.pending > 0 do
        local step = table.remove(walk.pending)

        if step.leaving ~= nil then
            inside[step.leaving] = nil
        else
            inside[step.value] = true
            table.insert(walk.pending, { leaving = step.value })

            local complaint = open(walk, step --[[@as TntMessageBodyStep]])

            if complaint ~= nil then
                return complaint
            end
        end
    end

    return nil
end

--- Проверяет тело: простые данные в пределах либо исключение.
---
--- Негодное тело — ошибка программиста: его собрало само приложение,
--- и отказ показывает на строку того, кто отправлял.
---@param body any
---@param level integer Уровень вины в кадрах вызывающего эту функцию
function Module.check(body, level)
    local complaint = Module.explain(body)

    if complaint ~= nil then
        error(complaint, level + 1)
    end
end

return Module
