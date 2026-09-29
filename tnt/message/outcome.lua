--- Итог обработчика: настройки получателя и приговор — подтвердить,
--- вернуть с отсрочкой или зарыть.
---
--- **Подтверждение — то, что вернул обработчик**, а не вызов, который можно
--- забыть. Значение или ничего — подтвердить; `nil, err` или `false, err` —
--- вернуть с отсрочкой `err.retry_after`, иначе по отступу, а выдача номер
--- `max_attempts` — зарыть с причиной «попыток N из M»; `err.retriable ==
--- false` — зарыть сразу: повтор негодного тела ничего не даст; исключение —
--- как отказ, причина — его текст.
---
--- **Отказ читается по полям, а не по типу**: обработчик пишется, не зная,
--- кто его позовёт и чей отказ он вернёт, — хранилища, клиента HTTP или
--- свой. Таблица без `retriable` и строка — повторяемый отказ.
--- `retry_after` читается `tonumber`: клиент HTTP кладёт туда заголовок
--- `Retry-After` как пришёл, строкой, и обработчик, вернувший отказ 429
--- как есть, повторяется тогда, когда просил сервер. Дата в `Retry-After`,
--- отрицательное и NaN числом секунд не читаются — повтор идёт по отступу:
--- дата меряется часами сервера, а они расходятся с нашими.
---
--- **Один порядок аргументов у всех**: `decide(ok, value, err, attempt,
--- policy)` — первые три значения ровно те, что отдаёт `xpcall`
--- обработчика, и приговор пишется одной строкой после него.

local must = require('tnt.must')

local envelope = require('tnt.message.envelope')
local options = require('tnt.message.options')

local Module = {}

--- Приговоры: подтвердить, вернуть на выдачу с отсрочкой, зарыть
--- до решения человека.
Module.ACK, Module.RETRY, Module.BURY = 'ack', 'retry', 'bury'

--- Умолчания получателя: один работник, пять выдач, отступ от секунды
--- до минуты.
Module.WORKERS = 1
Module.MAX_ATTEMPTS = 5
Module.BACKOFF_BASE = 1
Module.BACKOFF_MAX = 60

--- Как зовутся настройки получателя в отказе, если пакет не назвал иначе.
Module.CONSUME = 'настройки получателя'

--- Настройки получателя: незнакомый ключ — исключение. `atomic` описан
--- любым значением: у очереди, которая его не умеет, о нём говорит свой
--- отказ, а не «логическое значение, а не число».
local SPEC = {
    workers = '?integer',
    max_attempts = '?integer',
    backoff = '?table',
    atomic = '?',
}

--- Настройки отступа.
local BACKOFF = { base = '?number', max = '?number' }

---@class TntMessagePolicy Настройки получателя с умолчаниями
---@field workers integer Сколько обработчиков идёт разом
---@field max_attempts integer После этой выдачи неудача зарывает
---@field backoff { base: number, max: number } Отступ перед повтором, секунды
---@field atomic boolean Запись обработчика и подтверждение — одна транзакция

---@class TntMessageReceiving : TntMessageExplained Как пакет называет настройки получателя
---@field own table<string, any>|nil Свои настройки пакета: имя → описание `must.options`

--- Проверяет настройки получателя и ставит умолчания; негодные —
--- исключение на строке того, кто объявил получателя.
---
--- Вторым значением отдаются настройки как пришли: свои настройки пакета
--- (`how.own`) проверены по роду, а границы и умолчания у них — забота
--- пакета.
---@param opts any
---@param features table<string, boolean> Признаки очереди: `atomic = false` — не умеет
---@param level integer Уровень вины в кадрах вызывающего эту функцию
---@param how TntMessageReceiving|nil
---@return TntMessagePolicy policy
---@return table given
function Module.policy(opts, features, level, how)
    local blame = level + 1
    local caller = must.at(blame)
    local explained = how or {}
    local what = explained.what or Module.CONSUME
    local spec = table.copy(SPEC)

    for name, rule in pairs(explained.own or {}) do
        spec[name] = rule
    end

    local given = caller.optional.options(opts, what, spec) or {}

    options.features(given, { 'atomic' }, features, blame, {
        what = what,
        unable = explained.unable,
        cannot = explained.cannot,
    })

    local backoff = caller.optional.options(given.backoff, what .. '.backoff', BACKOFF) or {}

    caller.optional.boolean(given.atomic, what .. '.atomic')
    caller.optional.positive(given.workers, what .. '.workers')
    caller.optional.positive(given.max_attempts, what .. '.max_attempts')
    caller.optional.between(backoff.base, what .. '.backoff.base', 0, options.MAX_SECONDS)
    caller.optional.between(backoff.max, what .. '.backoff.max', 0, options.MAX_SECONDS)

    local policy = {
        workers = given.workers or Module.WORKERS,
        max_attempts = given.max_attempts or Module.MAX_ATTEMPTS,
        backoff = {
            base = backoff.base or Module.BACKOFF_BASE,
            max = backoff.max or Module.BACKOFF_MAX,
        },
        atomic = given.atomic == true,
    }

    return policy, given
end

--- Текст причины: у таблицы с полем `message` — оно, иначе `tostring`.
---
--- Отказ `{ retry_after = 0.2, message = 'подождите' }` без метатаблицы
--- показался бы в журнале и у зарытого адресом «table: 0x…».
---@param reason any
---@return string
function Module.text(reason)
    local said = type(reason) == 'table' and reason.message

    if type(said) == 'string' then
        return said
    end

    return tostring(reason)
end

--- Отсрочка повтора: `retry_after` отказа, если он читается неотрицательным
--- числом секунд, иначе отступ `base · 2^(attempt−1)`, но не больше `max`.
---@param reason any
---@param attempt integer
---@param policy TntMessagePolicy
---@return number
local function delay_of(reason, attempt, policy)
    local asked = type(reason) == 'table' and tonumber(reason.retry_after) or nil

    -- NaN и отрицательное сравнение не проходят; бесконечность — потолок.
    if asked ~= nil and asked >= 0 then
        return math.min(asked, options.MAX_SECONDS)
    end

    return math.min(policy.backoff.max, policy.backoff.base * 2 ^ (attempt - 1))
end

--- Приговор обработчику.
---
--- `ok` — дошёл ли обработчик до возврата; если нет, `value` — то, что он
--- бросил. Второе значение приговора — отсрочка у `retry` и причина
--- у `bury`; у `ack` его нет.
---@param ok boolean
---@param value any Первое значение обработчика либо брошенное
---@param err any Второе значение обработчика
---@param attempt integer Номер выдачи
---@param policy TntMessagePolicy
---@return string verdict
---@return number|string|nil extra
function Module.decide(ok, value, err, attempt, policy)
    if ok and (value or err == nil) then
        return Module.ACK
    end

    local reason = ok and err or value

    if type(reason) == 'table' and reason.retriable == false then
        return Module.BURY, Module.text(reason)
    end

    if attempt >= policy.max_attempts then
        return Module.BURY, ('попыток %d из %d: %s'):format(attempt, policy.max_attempts, Module.text(reason))
    end

    return Module.RETRY, delay_of(reason, attempt, policy)
end

--- Почему выданное зарывается, не доходя до обработчика; `nil` — не зарывается.
---
--- **Выдача сверх потолка** — прежние выдачи итога не вернули: сообщение,
--- которое роняет процесс, иначе выдавалось бы после каждого перезапуска
--- без конца. **Тело не по форме** — вход из очереди недоверенный,
--- и повтор его не исправит.
---@param message TntMessage
---@param policy TntMessagePolicy
---@param shape table|nil Форма тела `tnt-data`
---@return string|nil
function Module.refusal(message, policy, shape)
    local limit = policy.max_attempts

    if message.attempt > limit then
        return ('выдач %d при потолке %d: прежние выдачи итога не вернули'):format(
            message.attempt,
            limit
        )
    end

    if shape == nil then
        return nil
    end

    local _, errors = shape.from(message.body)

    if errors ~= nil then
        return 'тело не по форме: ' .. envelope.listed(errors)
    end

    return nil
end

return Module
