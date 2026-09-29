--- Крюки очереди: то, что приложение добавляет к отправке и к обработке
--- сверх настроек вызывающего, — отрезки трассы `producer` и `consumer`,
--- замер, своя запись.
---
--- Пакет очереди от трассировщика не зависит: знание о нём приходит
--- крюком. Крюк — `hook(call, proceed)`, где `call = { kind = 'send' |
--- 'handle', name, message }`:
---
---     queue.hook('timing', function(call, proceed)
---         local started = clock.monotonic()
---         local sent, err = proceed()
---
---         observe(call.kind, call.name, clock.monotonic() - started)
---
---         return sent, err
---     end)
---
--- На отправке конверт собирается **внутри** `proceed`: тогда заголовки
--- несут контекст, который завёл крюк, а `call.message` появляется после
--- `proceed`. На обработке конверт уже есть до крюка — из него крюк берёт
--- родителя трассы. Вид обращения один у всех очередей договора, и крюк,
--- написанный однажды, ставится каждой.
---
--- Крюки идут снаружи внутрь в порядке постановки. Сорвавшийся крюк
--- обработку не срывает: бросивший и не позвавший `proceed` пропускаются —
--- `proceed` зовёт пакет сам, — и пишется `warn` с именем крюка, с подавлением
--- повторов. Отменить отправку крюк не может: телеметрия не решает, уйдёт
--- ли сообщение. `proceed` исполняется один раз, сколько бы его ни звали,
--- и его итог — итог отправки либо обработки; что вернул сам крюк,
--- не читается. Бросок самого обращения — не срыв крюка: он уходит
--- вызывающему тем же значением, а обращение второй раз не исполняется.
---
--- **Список — состояние процесса, свой у каждого пакета**: очереди
--- объявляются и внутри других пакетов, и крюк, поставленный одной из них,
--- до других не дошёл бы. Список пакета берётся по его имени —
--- `hooks.of('tnt.queue')`, — и фасад пакета, и его работник получают один
--- и тот же.

local journal = require('tnt.log')
local must = require('tnt.must')
local raise = require('tnt.must.fail').raise

local Module = {}

--- Род обращения: отправка.
Module.SEND = 'send'

--- Род обращения: обработка.
Module.HANDLE = 'handle'

---@class TntMessageCall Что оборачивает крюк
---@field kind string `send` либо `handle`
---@field name string Назначение: очередь, тема, имя события
---@field message TntMessage|nil Конверт; у отправки — после `proceed`

---@alias TntMessageHook fun(call: TntMessageCall, proceed: fun(): ...): any

---@class TntMessageHooks Крюки одного пакета
---@field label string Имя пакета: им подписан журнал
---@field set fun(name: string, hook: TntMessageHook|nil) Ставит, заменяет или снимает крюк
---@field names fun(): string[] Имена поставленных крюков по порядку
---@field around fun(call: TntMessageCall, proceed: fun(): ...): ... Исполняет `proceed` внутри крюков

--- Списки крюков по именам пакетов.
---@type table<string, TntMessageHooks>
local lists = {}

--- Значения с их числом: пустота в середине итога не теряется.
---@param ... any
---@return table
local function pack(...)
    return { n = select('#', ...), ... }
end

--- Один крюк вокруг остатка цепочки.
---
--- Остаток исполняется под `pcall`, и его бросок — не срыв крюка. Крюк,
--- который пропустил бросок `proceed` наружу, поступил так, как и должен,
--- а числись он сорвавшимся — пакет позвал бы остаток второй раз
--- и отправил бы сообщение, чья отправка уже бросила. Бросок остатка
--- уходит вызывающему тем же значением, что бы ни сделал с ним крюк.
---@param log table Журнал пакета с подавлением повторов
---@param entry { name: string, hook: TntMessageHook }
---@param call TntMessageCall
---@param inner fun(): ...
---@return any ... Итог остатка
local function guarded(log, entry, call, inner)
    --- Исход остатка — то, что отдал `pcall`, с числом значений.
    ---@type table|nil
    local outcome = nil

    local function proceed()
        if outcome == nil then
            outcome = pack(pcall(inner))
        end

        if not outcome[1] then
            raise(outcome[2])
        end

        return unpack(outcome, 2, outcome.n)
    end

    local ok, err = pcall(entry.hook, call, proceed)

    if outcome == nil or (outcome[1] and not ok) then
        log.warn('крюк сорвался и пропущен', {
            hook = entry.name,
            kind = call.kind,
            destination = call.name,
            err = ok and 'крюк не позвал proceed' or tostring(err),
        })
    end

    return proceed()
end

--- Заводит список крюков пакета.
---@param label string
---@return TntMessageHooks
local function listed(label)
    --- Журнал с подавлением повторов: крюк, бросающий на каждом сообщении,
    --- иначе писал бы одну и ту же строку на каждое.
    local log = journal.changes(label)

    --- Поставленные крюки по порядку.
    ---@type { name: string, hook: TntMessageHook }[]
    local installed = {}

    local hooks = { label = label }

    --- Ставит, заменяет или снимает крюк. Замена оставляет крюк на прежнем
    --- месте: крюк ставят и при старте, и при перечитывании настроек,
    --- и порядок от этого меняться не должен.
    ---@param name string Имя крюка, например `timing`
    ---@param hook TntMessageHook|nil Крюк; `nil` снимает
    function hooks.set(name, hook)
        local caller = must.at(2)

        caller.not_empty(name, 'имя крюка')
        caller.optional.callable(hook, 'крюк')

        for index, entry in ipairs(installed) do
            if entry.name == name then
                if hook == nil then
                    table.remove(installed, index)
                else
                    entry.hook = hook
                end

                return
            end
        end

        if hook ~= nil then
            table.insert(installed, { name = name, hook = hook })
        end
    end

    --- Имена поставленных крюков в порядке постановки.
    ---@return string[]
    function hooks.names()
        local names = {}

        for index, entry in ipairs(installed) do
            names[index] = entry.name
        end

        return names
    end

    --- Исполняет `proceed` внутри всех крюков и отдаёт его итог.
    ---
    --- Цепочка собирается целиком до исполнения, от конца списка к началу:
    --- крюк, поставленный посреди обращения, достаётся только следующему.
    ---@param call TntMessageCall
    ---@param proceed fun(): ...
    ---@return any ...
    function hooks.around(call, proceed)
        local chain = proceed

        for index = #installed, 1, -1 do
            local entry = installed[index]
            local inner = chain

            chain = function()
                return guarded(log, entry, call, inner)
            end
        end

        return chain()
    end

    return hooks
end

--- Список крюков пакета по его имени: один на процесс.
---@param label string Имя пакета, например `tnt.queue`; им же подписан журнал
---@return TntMessageHooks
function Module.of(label)
    must.at(2).not_empty(label, 'имя пакета')

    if lists[label] == nil then
        lists[label] = listed(label)
    end

    return lists[label]
end

return Module
