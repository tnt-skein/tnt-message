--- Общие средства проверок общей части договора очереди.
---
--- Пакет чистый: ни `box`, ни сети, ни часов, которые надо двигать, —
--- всё проверяется в процессе. Ряды договора читаются из реестра
--- встроенного `metrics` так, как их видит сборщик (`value`, `samples`).
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.must`, `tnt.context`, `tnt.id`, `tnt.clock`, `tnt.log`,
--- `tnt.external` — берутся из `.rocks` обычным `require`: проверяется
--- этот пакет, а не они. Общий способ объявить ряд — тоже из `.rocks`,
--- но файлами (`MODULES`).
---
--- Оснастка в `test/testing/` — загрузчик исходников и ловушка журнала —
--- грузится так же, файлами, и один раз на процесс: второй экземпляр
--- загрузчика не знал бы, что вытеснил первый, и не вернул бы вытесненное
--- на место.

local fio = require('fio')
local t = require('luatest')

--- Реестр встроенного metrics: его методов в аннотациях ядра нет.
---@type any
local registry = require('metrics')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    module = package.loaded['tnt.testing.sources'].module,
    capture_log = package.loaded['tnt.testing.journal'].capture,
}

--- Имена модулей пакета в порядке зависимостей.
local OWN = {
    'tnt.message.body',
    'tnt.message.options',
    'tnt.message.envelope',
    'tnt.message.outcome',
    'tnt.message.hook',
    'tnt.message.scope',
    'tnt.message',
    'tnt.message.series',
}

--- Средства проверок общей части.
---@class TntMessageTestHelper
---@field message table Фасад пакета
---@field body table Тело
---@field options table Настройки отправки и признаки
---@field envelope table Конверт
---@field outcome table Приговор и настройки получателя
---@field hook table Крюки
---@field scope table Область обработчика
---@field series table Ряды метрик договора
---@field context table Контекст файбера
---@field log table Журнал
---@field journal table Ловушка журнала
local helper = {
    --- Модули в порядке зависимостей: общий способ объявить ряд, затем
    --- пакет — имя и путь исходника.
    ---
    --- Общий способ объявить ряд — файлами из `.rocks`, свой экземпляр
    --- на каждую загрузку помощника, а не `require`. Ряды — состояние
    --- процесса: повторное объявление отдаёт прежний ряд и ставит шкале
    --- глубины источник последней загрузки, и с одним экземпляром на процесс
    --- глубину собирал бы пакет последнего загруженного файла проверок,
    --- а не тот, что под проверкой. Со своим экземпляром ряды каждой
    --- загрузки возвращаются в реестр первым же наблюдением.
    MODULES = {
        { name = 'tnt.metrics.series.labels', path = '.rocks/share/tarantool/tnt/metrics/series/labels.lua' },
        { name = 'tnt.metrics.series.collector', path = '.rocks/share/tarantool/tnt/metrics/series/collector.lua' },
        { name = 'tnt.metrics.series', path = '.rocks/share/tarantool/tnt/metrics/series.lua' },
    },
}

for _, name in ipairs(OWN) do
    table.insert(helper.MODULES, { name = name, path = (name:gsub('%.', '/')) .. '.lua' })
end

--- Фасад пакета из исходников: грузится один раз на процесс — состояние
--- у пакета одно, списки крюков, и проверки снимают свои крюки сами.
helper.message = testing.load_sources(helper.MODULES, 'tnt.message')

-- Части пакета берутся из той же загрузки, что и фасад: взятые `require`,
-- они пришли бы установленной копией из `.rocks`.
for _, part in ipairs({ 'body', 'options', 'envelope', 'outcome', 'hook', 'scope', 'series' }) do
    helper[part] = testing.module('tnt.message.' .. part)
end

helper.context = require('tnt.context')
helper.log = require('tnt.log')

--- Ловушка журнала: запись о броске обработчика и о сорвавшемся крюке
--- видна только ею.
helper.journal = testing.capture_log()

--- Совпадают ли метки: одинаковый набор имён с одинаковыми значениями.
---@param left table
---@param right table
---@return boolean
local function same_labels(left, right)
    for name, value in pairs(left) do
        if right[name] ~= value then
            return false
        end
    end

    for name in pairs(right) do
        if left[name] == nil then
            return false
        end
    end

    return true
end

--- Наблюдения реестра по имени ряда — после источников шкал, как их
--- собирает выкладка.
---@param name string
---@return table[]
function helper.samples(name)
    local found = {}

    for _, observation in ipairs(registry.collect({ invoke_callbacks = true })) do
        if observation.metric_name == name then
            table.insert(found, observation)
        end
    end

    return found
end

--- Что увидит сборщик: число ряда с ровно такими метками.
---@param name string
---@param labels table|nil
---@return number|nil
function helper.value(name, labels)
    for _, observation in ipairs(helper.samples(name)) do
        if same_labels(observation.label_pairs, labels or {}) then
            return observation.value
        end
    end

    return nil
end

--- Сверяет, что каждый вызов бросает названный отказ и винит строку
--- вызова в файле проверок, а не внутри пакета.
---
--- Вызов стоит в замыкании первой строкой тела, то есть строкой ниже
--- слова `function`: место броска сверяется с ней целиком — файлом,
--- строкой и текстом.
---@param cases table[] Пары: замыкание с вызовом и текст броска
function helper.assert_blamed(cases)
    for _, case in ipairs(cases) do
        local _, err = pcall(case[1])
        local info = debug.getinfo(case[1], 'S') --[[@as { short_src: string, linedefined: integer }]]

        t.assert_equals(err, ('%s:%d: %s'):format(info.short_src, info.linedefined + 1, case[2]))
    end
end

--- Значение мимо проверки типов: негодный аргумент нарочно.
---@param value any
---@return any
function helper.wrong(value)
    return value
end

--- Снимает все крюки списка: список — состояние процесса, и оставленный
--- крюк достался бы соседней проверке.
---@param hooks TntMessageHooks
function helper.forget_hooks(hooks)
    for _, name in ipairs(hooks.names()) do
        hooks.set(name, nil)
    end
end

--- Настройки получателя с умолчаниями у очереди, которая умеет всё;
--- негодные винят строку того, кто позвал помощника.
---@param opts table|nil
---@return TntMessagePolicy
function helper.policy(opts)
    return (helper.outcome.policy(opts, {}, 2))
end

--- Тело: цепочка из `levels` вложенных таблиц под корнем — всего таблиц
--- на одну больше.
---@param levels integer
---@return table
function helper.deep(levels)
    local root = {}
    local node = root

    for _ = 1, levels do
        node.next = {}
        node = node.next
    end

    return root
end

--- Тело: список из `count` чисел — значений в нём на одно больше, считая
--- сам список.
---@param count integer
---@return table
function helper.wide(count)
    local list = {}

    for index = 1, count do
        list[index] = index
    end

    return list
end

--- Тело: одна таблица в двух ветках на каждом из `levels` уровней — кодек
--- пишет её столько раз, сколько на неё ссылок.
---@param levels integer
---@return table
function helper.shared(levels)
    local node = { leaf = 1 }

    for _ = 1, levels do
        node = { left = node, right = node }
    end

    return node
end

return helper
