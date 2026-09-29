--- Ряды метрик договора очереди: отправлено, отказы отправки по роду,
--- итог обработки, истекло, сбои работника, ожидание первой выдачи
--- и глубина.
---
---     local series = require('tnt.message.series')
---
---     series.count(queue.counts, queue.name, 'ack')   -- счётчик status() и ряд
---     series.refused(queue.name, err)                -- отказ отправки по роду
---     series.taken(queue.name, envelope)             -- ожидание первой выдачи
---     series.depth('tnt.jobs', function()
---         return { [queue.name] = { ready = 3, taken = 1 } }
---     end)
---
--- **Ряды одни на весь договор**: имена `message_*` и метка `destination`
--- одинаковы у очереди в спейсах, шины внутри узла и клиентов брокеров,
--- и панель, собранная для одной очереди, читает любую. Поэтому
--- объявление одно и лежит здесь: повторное объявление с другим описанием
--- или другими метками реестр отвергает исключением, а копии, написанные
--- каждым пакетом своими словами, однажды разошлись бы.
---
--- **Счётчик `status()` и ряд растут в одном месте** — `count`: разойтись
--- им иначе ничто не мешало бы.
---
--- **Глубина — одна шкала со сбором на все пакеты.** Источник у шкалы один,
--- и пакет, объявивший её со своим источником, отнял бы ряд у соседа:
--- глубина очереди пропала бы из выкладки, как только приложение взяло
--- шину. Поэтому источник шкалы здесь, а пакеты кладут в него свои
--- по имени пакета — загруженный заново заменяет свой, а не добавляет
--- второй. Одно имя назначения у двух пакетов складывается, как
--- складываются их счётчики.
---
--- **Ожидание** — от отправки до первой выдачи, по стенным часам
--- отправителя: отметка `created` стоит в конверте, и другой у сообщения
--- нет.

local clock = require('tnt.clock')
local external = require('tnt.external')
local metrics = require('tnt.metrics.series')

local Module = {}

--- Сколько разных назначений видно в рядах. Очереди и события объявляет
--- код, а не данные, и больше сотни на узле — это уже ошибка в коде;
--- сверх потолка назначение идёт словом `_other`.
Module.DESTINATIONS = 100

--- Корзины ожидания, секунды: от десяти миллисекунд до часа — очередь
--- с отсрочкой ждёт минутами, а без неё — долями секунды.
Module.WAIT_BUCKETS = { 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 30, 60, 300, 900, 3600 }

--- Итоги обработки: те же слова, что у счётчиков `status()`.
local OUTCOMES = { 'ack', 'retry', 'bury', 'late' }

--- Роды отказа отправки — все роды договора. Ряд один у всех пакетов,
--- и род, которого у пакета не бывает, в выкладке просто не появляется;
--- список короче загнал бы отказ шины `overflow` и отказы брокеров
--- в слово `_other`.
local KINDS = { 'unreachable', 'denied', 'busy', 'timeout', 'broken', 'rejected', 'conflict', 'closed', 'overflow' }

--- Внешние средства: стенные часы — те же, что поставили `created`.
local source = external.install(Module, { realtime = clock.realtime })

local sent = metrics.counter('message_sent_total', {
    help = 'Сколько сообщений отправлено: по назначению',
    labels = { destination = Module.DESTINATIONS },
})

local failed = metrics.counter('message_send_failures_total', {
    help = 'Сколько отправок отказало: по назначению и роду отказа',
    labels = { destination = Module.DESTINATIONS, kind = KINDS },
})

local handled = metrics.counter('message_handled_total', {
    help = 'Сколько сообщений обработано: по назначению и итогу',
    labels = { destination = Module.DESTINATIONS, outcome = OUTCOMES },
})

local expired = metrics.counter('message_expired_total', {
    help = 'Сколько сообщений выброшено по сроку жизни ttl',
    labels = { destination = Module.DESTINATIONS },
})

local failures = metrics.counter('message_worker_failures_total', {
    help = 'Сколько шагов работника получателя сорвалось',
    labels = { destination = Module.DESTINATIONS },
})

local waited = metrics.histogram('message_wait_seconds', {
    help = 'Сколько сообщение ждало первой выдачи: от отправки до взятия работником, с отсрочкой',
    labels = { destination = Module.DESTINATIONS },
    buckets = Module.WAIT_BUCKETS,
})

--- Источники глубины по имени пакета: каждый отдаёт глубину своих
--- назначений по состояниям.
---@type table<string, fun(): table<string, table<string, number>>>
local sources = {}

--- Глубина всех назначений всех пакетов, сложенная по назначению
--- и состоянию.
---
--- Складывается до укладки: шкалу ставят, а не прибавляют, и второй пакет
--- с тем же именем назначения иначе затёр бы число первого.
---@param gauge TntMetricsSeries
local function sound(gauge)
    local totals = {}

    for _, measure in pairs(sources) do
        for name, depth in pairs(measure()) do
            local sum = totals[name] or {}

            for state, count in pairs(depth) do
                sum[state] = (sum[state] or 0) + count
            end

            totals[name] = sum
        end
    end

    for name, sum in pairs(totals) do
        for state, count in pairs(sum) do
            gauge:set(count, { destination = name, state = state })
        end
    end
end

metrics.gauge('message_depth', {
    help = 'Сколько сообщений лежит в очереди: по назначению и состоянию',
    labels = { destination = Module.DESTINATIONS, state = { 'ready', 'taken', 'delayed', 'dead' } },
    collect = sound,
})

--- Какой ряд растёт с каким счётчиком `status()`. Счётчика, которого здесь
--- нет (ожидание записи, пропавшее с остановкой), в рядах нет: это
--- не событие договора, а подробность пакета.
---@type table<string, fun(name: string)>
local COUNTERS = {
    sent = function(name)
        sent:inc(1, { destination = name })
    end,

    expired = function(name)
        expired:inc(1, { destination = name })
    end,

    failures = function(name)
        failures:inc(1, { destination = name })
    end,
}

for _, outcome in ipairs(OUTCOMES) do
    COUNTERS[outcome] = function(name)
        handled:inc(1, { destination = name, outcome = outcome })
    end
end

--- Считает событие назначения: и в счётчике `status()`, и в ряду.
---@param counts table<string, integer> Счётчики `status()` очереди, слушателя либо шины
---@param name string Имя назначения
---@param what string Имя счётчика: sent, ack, retry, bury, late, expired, failures
function Module.count(counts, name, what)
    counts[what] = counts[what] + 1
    COUNTERS[what](name)
end

--- Считает отказ отправки по роду.
---@param name string Имя назначения
---@param err TntStorageFailure
function Module.refused(name, err)
    failed:inc(1, { destination = name, kind = err.kind })
end

--- Меряет ожидание сообщения на первой выдаче.
---
--- Повторная выдача ждала отсрочки повтора, а не очереди, и в ожидание
--- не идёт; чужое содержимое очереди отметки отправки не несёт вовсе,
--- а конверт без отметки мерить не от чего — ряд не вправе сорвать
--- обработку. Часы разных узлов расходятся, и отрицательное ожидание —
--- это ноль.
---@param name string Имя назначения
---@param envelope TntMessage
function Module.taken(name, envelope)
    local created = envelope.created

    if envelope.attempt ~= 1 or envelope.foreign or type(created) ~= 'number' then
        return
    end

    waited:observe(math.max(source().realtime() - created, 0), { destination = name })
end

--- Ставит источник глубины пакета; `nil` снимает его.
---
--- Источник зовётся перед каждой выкладкой и отдаёт глубину своих
--- назначений: `{ [имя] = { ready = …, taken = …, delayed = …, dead = … } }`.
--- Назначение, которого источник не назвал, из ряда уходит само.
---@param owner string Имя пакета: тот же пакет, загруженный заново, заменяет свой источник
---@param measure (fun(): table<string, table<string, number>>)|nil
function Module.depth(owner, measure)
    sources[owner] = measure
end

return Module
