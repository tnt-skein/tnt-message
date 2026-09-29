--- Настройки отправки и признаки очереди.
---
--- **Настройки одни на все очереди**: `headers`, `key`, `delay`, `ttl`,
--- `priority`, `id`, `timeout`. Отправитель, переехавший с одной очереди
--- на другую, пишет те же слова, а незнакомое слово — исключение, а не
--- молчаливый пропуск: опечатка в имени настройки иначе молча отменяла бы
--- её.
---
--- **Настройка, которой очередь не умеет, — исключение**, и оно
--- говорит, почему не умеет. Что очередь умеет, она объявляет признаками
--- `features`, и у настроек `key`, `delay`, `ttl` и `priority` имя
--- настройки — имя признака. Обработчик, переехавший на очередь без
--- отсрочки с `delay`, должен упасть в проверках, а не начать получать
--- сообщения сразу. Признак проверяется раньше рода значения: о настройке,
--- которой очередь не умеет, важнее узнать, что она лишняя, чем что
--- она написана не тем родом.
---
--- **Сроки — не больше ста лет**: срок длиннее очередь в спейсе читает как
--- «никогда», и `delay` в тысячу лет молча стал бы вечным.

local key = require('tnt.context.key')
local must = require('tnt.must')

local Module = {}

--- Потолок сроков в секундах — сто лет по 365 суток.
Module.MAX_SECONDS = 365 * 86400 * 100

--- Как зовутся настройки отправки в отказе, если пакет не назвал иначе.
Module.SEND = 'настройки отправки'

--- Почему очередь не умеет признака, если пакет не объяснил сам.
Module.CANNOT = 'эта очередь не умеет'

--- Настройки отправки: незнакомый ключ — исключение.
local SPEC = {
    headers = '?table',
    key = '?not_empty',
    delay = '?number',
    ttl = '?number',
    priority = '?integer',
    id = '?not_empty',
    timeout = '?number',
}

--- Настройки, у которых есть признак, в постоянном порядке: из двух
--- запретных отказ называет всегда одну и ту же.
local FEATURED = { 'key', 'delay', 'ttl', 'priority' }

---@class TntMessageSendOptions Проверенные настройки отправки
---@field headers table<string, string>|nil Свои заголовки, главнее перенесённых
---@field key string|nil Ключ порядка
---@field delay number|nil Не выдавать раньше, секунды
---@field ttl number|nil Срок жизни, секунды
---@field priority integer|nil Порядок выдачи готовых: 0 — первым
---@field id string|nil Готовый опознаватель
---@field timeout number|nil Срок вызова, секунды

---@class TntMessageExplained Как пакет называет настройки и свои запреты
---@field what string|nil Имя настроек в отказе; по умолчанию `SEND`
---@field unable table<string, string>|nil Почему очередь не умеет признака — по имени
---@field cannot string|nil Почему не умеет, если причины по имени нет; по умолчанию `CANNOT`

--- Отказ настройке, которой очередь не умеет.
---@param what string
---@param name string
---@param how TntMessageExplained
---@return string
local function refused(what, name, how)
    local reason = (how.unable or {})[name] or how.cannot or Module.CANNOT

    return ('%s: «%s» — %s'):format(what, name, reason)
end

--- Отказывает признаку, которого у очереди нет: `features[name] == false`.
---
--- Признак, которого очередь вовсе не назвала, считается умением: пакет
--- с неполными признаками не лишает отправителя настроек молча.
---@param given table|nil Настройки как пришли
---@param names string[] Какие признаки сверять, по порядку
---@param features table<string, boolean>
---@param level integer Уровень вины в кадрах вызывающего эту функцию
---@param how TntMessageExplained
function Module.features(given, names, features, level, how)
    local what = how.what or Module.SEND

    for _, name in ipairs(names) do
        if given ~= nil and given[name] ~= nil and features[name] == false then
            error(refused(what, name, how), level + 1)
        end
    end
end

--- Проверяет настройки отправки по признакам очереди; негодные —
--- исключение на строке того, кто позвал отправку.
---@param opts any
---@param features table<string, boolean> Признаки очереди: `false` — не умеет
---@param level integer Уровень вины в кадрах вызывающего эту функцию
---@param how TntMessageExplained|nil
---@return TntMessageSendOptions
function Module.check(opts, features, level, how)
    local blame = level + 1
    local caller = must.at(blame)
    local explained = how or {}
    local what = explained.what or Module.SEND

    caller.optional.table(opts, what)
    Module.features(opts, FEATURED, features, blame, explained)

    local given = caller.optional.options(opts, what, SPEC) or {}

    caller.optional.between(given.delay, what .. '.delay', 0, Module.MAX_SECONDS)
    caller.optional.positive(given.ttl, what .. '.ttl')
    caller.optional.less_than(given.ttl, what .. '.ttl', Module.MAX_SECONDS)
    caller.optional.non_negative(given.priority, what .. '.priority')
    caller.optional.positive(given.timeout, what .. '.timeout')

    for name, value in pairs(given.headers or {}) do
        caller.matches(name, 'имя заголовка', key.HEADER_PATTERN)
        caller.string(value, ('заголовок %s'):format(name))
    end

    return given
end

return Module
