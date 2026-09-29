--- Область обработчика: контекст отправителя, крюки, приговор.
---
--- **Обработчик идёт в контексте того, кто отправил**: заголовки конверта
--- разбираются `context.import` — вход из очереди недоверенный, и в область
--- попадают только объявленные ключи. Без `request_id` в заголовках
--- у сообщения свой ULID: запись обработчика без опознавателя в журнале
--- не найти. Повторная выдача несёт те же заголовки — и тот же
--- опознаватель запроса: это одна история.
---
--- **Крюки `handle` оборачивают обработчик** вместе с областью: крюк трассы
--- берёт родителя из заголовков конверта и видит контекст обработчика.
---
--- **Бросок обработчика — отказ с его текстом**, и пишется `error`
--- со стеком: стек берётся в обработчике `xpcall`, после раскрутки его
--- уже нет. Тело сообщения в журнал не пишется: в нём бывают персональные
--- данные.

local context = require('tnt.context')
local id = require('tnt.id')

local hook = require('tnt.message.hook')
local outcome = require('tnt.message.outcome')

local Module = {}

---@class TntMessageCaught Что бросил обработчик, отдельно от стека
---@field err any Брошенное
---@field traceback string Стек в миг броска

---@alias TntMessageInvoke fun(message: TntMessage): boolean, any, any

--- Обработчик `xpcall`: брошенное и стек отдельно.
---@param err any
---@return TntMessageCaught
function Module.caught(err)
    return { err = err, traceback = debug.traceback('', 2) }
end

--- Исполнение обработчика по умолчанию: `xpcall` с отдельным стеком.
---
--- Пакет, которому нужно больше — транзакция вокруг обработчика, — пишет
--- своё исполнение с тем же `caught`: приговор ждёт от него то же, что
--- отдаёт `xpcall`.
---@param handler fun(message: TntMessage): any, any Обработчик приложения
---@return TntMessageInvoke
function Module.invoker(handler)
    return function(message)
        return xpcall(handler, Module.caught, message)
    end
end

--- Исполняет обработчик для выданного сообщения и выносит приговор.
---@param hooks TntMessageHooks Крюки пакета
---@param log table Журнал пакета: туда пишется бросок обработчика
---@param message TntMessage Конверт
---@param policy TntMessagePolicy Настройки получателя
---@param invoke TntMessageInvoke Исполнение обработчика
---@return string verdict
---@return number|string|nil extra Отсрочка у `retry`, причина у `bury`
function Module.judge(hooks, log, message, policy, invoke)
    local values = context.import(message.headers)

    values.request_id = values.request_id or id.ulid()

    local call = { kind = hook.HANDLE, name = message.name, message = message }
    local ok, value, err = context.run(values, hooks.around, call, function()
        return invoke(message)
    end)

    if not ok then
        log.error('обработчик сообщения бросил', {
            destination = message.name,
            id = message.id,
            attempt = message.attempt,
            err = tostring(value.err),
            traceback = value.traceback,
        })
        value = value.err
    end

    return outcome.decide(ok, value, err, message.attempt, policy)
end

return Module
