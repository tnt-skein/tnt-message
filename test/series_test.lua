--- Ряды договора: что растёт с каким счётчиком, отказ отправки по роду,
--- ожидание первой выдачи и глубина, сложенная из источников пакетов.
---
--- Ряды читаются из реестра встроенного `metrics` так, как их видит
--- сборщик. Имена назначений у каждой проверки свои: реестр общий на
--- процесс, и числа соседней проверки остаются в нём.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local series = helper.series

local g = t.group('tnt.message.series')

--- Счётчики `status()` с нуля — как у очереди, слушателя или шины.
---@return table<string, integer>
local function zeroed()
    return { sent = 0, ack = 0, retry = 0, bury = 0, late = 0, expired = 0, failures = 0 }
end

--- Глубина назначения по состояниям — так, как её видит сборщик.
---
--- Сначала — наблюдение: проверки соседних пакетов в том же процессе
--- кладут в реестр ряды своей загрузки, и наши возвращает туда первое же
--- наблюдение.
---@param name string
---@return table<string, number>
local function depth_of(name)
    series.count(zeroed(), 'series_depth_probe', 'sent')

    local found = {}

    for _, sample in ipairs(helper.samples('message_depth')) do
        if sample.label_pairs.destination == name then
            found[sample.label_pairs.state] = sample.value
        end
    end

    return found
end

g.after_each(function()
    series._set_source(nil)

    for _, owner in ipairs({ 'series.first', 'series.second' }) do
        series.depth(owner, nil)
    end
end)

g.test_each_counter_of_the_status_grows_its_row = function()
    local counts = zeroed()

    for _, what in ipairs({ 'sent', 'sent', 'ack', 'retry', 'bury', 'late', 'expired', 'failures' }) do
        series.count(counts, 'series_counts', what)
    end

    t.assert_equals(counts, { sent = 2, ack = 1, retry = 1, bury = 1, late = 1, expired = 1, failures = 1 })

    local destination = { destination = 'series_counts' }

    t.assert_equals(helper.value('message_sent_total', destination), 2)
    t.assert_equals(helper.value('message_expired_total', destination), 1)
    t.assert_equals(helper.value('message_worker_failures_total', destination), 1)

    for _, outcome in ipairs({ 'ack', 'retry', 'bury', 'late' }) do
        t.assert_equals(
            helper.value('message_handled_total', { destination = 'series_counts', outcome = outcome }),
            1,
            outcome
        )
    end
end

g.test_a_refused_send_is_counted_by_its_kind = function()
    local kinds = { 'unreachable', 'denied', 'busy', 'timeout', 'broken', 'rejected', 'conflict', 'closed', 'overflow' }

    for _, kind in ipairs(kinds) do
        series.refused('series_refused', { kind = kind })
    end

    series.refused('series_refused', { kind = 'strange' })

    table.insert(kinds, '_other')

    for _, kind in ipairs(kinds) do
        t.assert_equals(
            helper.value('message_send_failures_total', { destination = 'series_refused', kind = kind }),
            1,
            kind
        )
    end
end

--- Ожидания назначения: число и сумма, и сколько легло в корзины до
--- секунды и до десяти миллисекунд.
---@param name string
---@return { count: number|nil, sum: number|nil, fast: number|nil, zero: number|nil }
local function waits(name)
    local destination = { destination = name }

    return {
        count = helper.value('message_wait_seconds_count', destination),
        sum = helper.value('message_wait_seconds_sum', destination),
        fast = helper.value('message_wait_seconds_bucket', { destination = name, le = 1 }),
        zero = helper.value('message_wait_seconds_bucket', { destination = name, le = 0.01 }),
    }
end

--- Стенные часы ряда стоят на тысяче.
local function at_thousand()
    series._set_source({
        realtime = function()
            return 1000
        end,
    })
end

g.test_the_wait_is_measured_on_the_first_delivery_only = function()
    at_thousand()

    series.taken('series_wait', { attempt = 1, created = 998 })
    series.taken('series_wait', { attempt = 2, created = 990 })
    series.taken('series_wait', { attempt = 1, created = 900, foreign = true })
    series.taken('series_wait', { attempt = 0, created = 900 })
    series.taken('series_wait', { attempt = 1 })
    series.taken('series_wait', { attempt = 1, created = 'вчера' })

    t.assert_equals(waits('series_wait'), { count = 1, sum = 2, fast = 0, zero = 0 })
end

g.test_a_wait_from_a_clock_ahead_is_zero = function()
    at_thousand()

    series.taken('series_ahead', { attempt = 1, created = 1003 })
    series.taken('series_ahead', { attempt = 1, created = 999.5 })

    t.assert_equals(waits('series_ahead'), { count = 2, sum = 0.5, fast = 2, zero = 1 })
end

g.test_the_wait_buckets_reach_an_hour = function()
    series.taken('series_buckets', { attempt = 1, created = 0 })

    local bounds = {}

    for _, sample in ipairs(helper.samples('message_wait_seconds_bucket')) do
        if sample.label_pairs.destination == 'series_buckets' then
            table.insert(bounds, sample.label_pairs.le)
        end
    end

    t.assert_equals(bounds, { 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 30, 60, 300, 900, 3600, math.huge })
    t.assert_equals(series.WAIT_BUCKETS, { 0.01, 0.05, 0.1, 0.5, 1, 5, 10, 30, 60, 300, 900, 3600 })
    t.assert_equals(series.DESTINATIONS, 100)
end

g.test_the_depth_of_two_packages_adds_up_by_destination_and_state = function()
    series.depth('series.first', function()
        return { series_shared = { ready = 2, dead = 1 }, series_first = { ready = 0 } }
    end)
    series.depth('series.second', function()
        return { series_shared = { ready = 3, delayed = 4 } }
    end)

    t.assert_equals(depth_of('series_shared'), { ready = 5, delayed = 4, dead = 1 })
    t.assert_equals(depth_of('series_first'), { ready = 0 }, 'ноль — тоже строка ряда')
end

g.test_the_depth_is_asked_anew_at_every_collection = function()
    local depth = { ready = 1, taken = 2 }

    series.depth('series.first', function()
        return { series_asked = depth }
    end)

    t.assert_equals(depth_of('series_asked'), { ready = 1, taken = 2 })

    depth = { ready = 7 }

    t.assert_equals(
        depth_of('series_asked'),
        { ready = 7 },
        'состояние, которого не назвали, ушло'
    )
end

g.test_a_package_loaded_again_replaces_its_source = function()
    series.depth('series.first', function()
        return { series_replaced = { ready = 1 } }
    end)
    series.depth('series.first', function()
        return { series_replaced = { ready = 9 } }
    end)

    t.assert_equals(
        depth_of('series_replaced'),
        { ready = 9 },
        'второй источник не сложен с первым'
    )

    series.depth('series.first', nil)

    t.assert_equals(depth_of('series_replaced'), {}, 'снятый источник строк не оставляет')
end
