--- Итог обработчика: настройки получателя, приговор и отказ до обработчика.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local outcome = helper.outcome

local g = t.group('tnt.message.outcome')

--- Приговор при настройках проверки.
---@param ok boolean
---@param value any
---@param err any
---@param attempt integer
---@param opts table|nil
---@return string verdict
---@return any extra
local function decide(ok, value, err, attempt, opts)
    return outcome.decide(ok, value, err, attempt, helper.policy(opts))
end

--- Отсрочка повтора первой выдачи при отступе от двух секунд.
---@param reason any
---@return any
local function delay_for(reason)
    return select(2, decide(true, nil, reason, 1, { backoff = { base = 2 } }))
end

--- Форма `tnt-data`: пропускает только число.
local NUMBER = {
    from = function(value)
        if type(value) == 'number' then
            return value
        end

        return nil, { [''] = 'число' }
    end,
}

g.test_the_policy_has_the_defaults_of_the_contract = function()
    t.assert_equals(helper.policy(nil), {
        workers = 1,
        max_attempts = 5,
        backoff = { base = 1, max = 60 },
        atomic = false,
    })
end

g.test_the_policy_takes_what_is_given = function()
    local policy, given = outcome.policy(
        { workers = 2, max_attempts = 3, backoff = { base = 0.1 }, atomic = true },
        {},
        1
    )

    t.assert_equals(policy, {
        workers = 2,
        max_attempts = 3,
        backoff = { base = 0.1, max = 60 },
        atomic = true,
    })
    t.assert_equals(given.workers, 2)
    t.assert_equals(helper.policy({ backoff = { max = 5 } }).backoff, { base = 1, max = 5 })
end

g.test_wrong_consumer_settings_are_raised_at_the_caller = function()
    helper.assert_blamed({
        {
            function()
                helper.policy({ worker = 2 })
            end,
            'настройки получателя: ключа «worker» нет, есть atomic, backoff, max_attempts, workers',
        },
        {
            function()
                helper.policy({ backoff = { basis = 1 } })
            end,
            'настройки получателя.backoff: ключа «basis» нет, есть base, max',
        },
        {
            function()
                helper.policy({ workers = 0 })
            end,
            'настройки получателя.workers — число больше 0, а не 0',
        },
        {
            function()
                helper.policy({ max_attempts = 0 })
            end,
            'настройки получателя.max_attempts — число больше 0, а не 0',
        },
        {
            function()
                helper.policy({ backoff = { base = -1 } })
            end,
            'настройки получателя.backoff.base — число от 0 до 3153600000, а не -1',
        },
        {
            function()
                helper.policy({ backoff = { max = 3153600001 } })
            end,
            'настройки получателя.backoff.max — число от 0 до 3153600000, а не 3153600001',
        },
        {
            function()
                helper.policy({ atomic = helper.wrong(1) })
            end,
            'настройки получателя.atomic — логическое значение, а не число',
        },
    })
end

g.test_atomic_the_queue_cannot_do_is_refused_with_its_reason = function()
    local unable = { atomic = 'брокер не умеет — подтверждение уходит по сети' }

    helper.assert_blamed({
        {
            function()
                outcome.policy({ atomic = false }, { atomic = false }, 1, { unable = unable })
            end,
            'настройки получателя: «atomic» — брокер не умеет — подтверждение уходит по сети',
        },
        {
            function()
                outcome.policy(
                    { atomic = 'да' },
                    { atomic = false },
                    1,
                    { what = 'настройки слушателя' }
                )
            end,
            'настройки слушателя: «atomic» — эта очередь не умеет',
        },
        {
            function()
                outcome.policy({ atomic = true }, { atomic = false }, 1, { cannot = 'шина не умеет' })
            end,
            'настройки получателя: «atomic» — шина не умеет',
        },
    })

    t.assert_equals(outcome.policy(nil, { atomic = false }, 1).atomic, false)
end

g.test_own_settings_of_the_package_are_checked_by_kind_and_given_back = function()
    local how = { what = 'настройки слушателя', own = { capacity = '?integer' } }
    local policy, given = outcome.policy({ capacity = 10, workers = 2 }, {}, 1, how)

    t.assert_equals(given.capacity, 10)
    t.assert_equals(
        policy.capacity,
        nil,
        'умолчания своих настроек — забота пакета'
    )
    t.assert_equals(policy.workers, 2)

    helper.assert_blamed({
        {
            function()
                outcome.policy({ capacity = 0.5 }, {}, 1, how)
            end,
            'настройки слушателя.capacity — целое число, а не 0.5',
        },
        {
            function()
                outcome.policy({ capacity = 1 }, {}, 1)
            end,
            'настройки получателя: ключа «capacity» нет, есть atomic, backoff, max_attempts, workers',
        },
    })
end

g.test_a_handler_that_returned_a_value_or_nothing_is_acknowledged = function()
    t.assert_equals({ decide(true, nil, nil, 1) }, { 'ack' })
    t.assert_equals({ decide(true, 'готово', nil, 1) }, { 'ack' })
    t.assert_equals({ decide(true, false, nil, 1) }, { 'ack' })
    t.assert_equals({ decide(true, 'готово', 'отказ рядом со значением', 1) }, { 'ack' })
end

g.test_a_pair_is_retried_with_a_backoff_that_doubles = function()
    local backoff = { base = 0.1, max = 1 }

    t.assert_equals(
        { decide(true, nil, 'сервис недоступен', 1, { backoff = backoff }) },
        { 'retry', 0.1 }
    )
    t.assert_equals({ decide(true, nil, 'нет', 2, { backoff = backoff }) }, { 'retry', 0.2 })
    t.assert_equals({ decide(true, false, 'нет', 3, { backoff = backoff }) }, { 'retry', 0.4 })
    t.assert_equals({ decide(true, nil, 'нет', 4, { backoff = { base = 0.1, max = 0.3 } }) }, { 'retry', 0.3 })
end

g.test_the_last_attempt_buries_with_the_count_in_the_reason = function()
    t.assert_equals({ decide(true, nil, 'сервис недоступен', 2, { max_attempts = 3 }) }, { 'retry', 2 })
    t.assert_equals(
        { decide(true, nil, 'сервис недоступен', 3, { max_attempts = 3 }) },
        { 'bury', 'попыток 3 из 3: сервис недоступен' }
    )
    t.assert_equals(
        { decide(true, nil, 'сервис недоступен', 7, { max_attempts = 3 }) },
        { 'bury', 'попыток 7 из 3: сервис недоступен' },
        'выдач больше потолка — тоже зарыть'
    )
end

g.test_a_failure_that_is_not_retriable_is_buried_at_once = function()
    t.assert_equals(
        { decide(true, nil, { retriable = false, message = 'тело не прошло проверку' }, 1) },
        { 'bury', 'тело не прошло проверку' }
    )
    t.assert_equals({ decide(true, nil, { retriable = true, message = 'ещё раз' }, 1) }, { 'retry', 1 })
end

g.test_a_raised_handler_is_a_failure_with_its_text = function()
    t.assert_equals(
        { decide(false, 'app.lua:5: деление на ноль', nil, 2, { max_attempts = 2 }) },
        { 'bury', 'попыток 2 из 2: app.lua:5: деление на ноль' }
    )
    t.assert_equals(
        { decide(false, { retriable = false, message = 'брошено' }, nil, 1) },
        { 'bury', 'брошено' }
    )
    t.assert_equals(
        { decide(false, nil, nil, 1) },
        { 'retry', 1 },
        'брошенная пустота — тоже отказ'
    )
end

g.test_retry_after_of_the_failure_is_the_delay = function()
    t.assert_equals(delay_for({ retry_after = 0.2 }), 0.2)
    t.assert_equals(delay_for({ retry_after = 0 }), 0)
end

g.test_retry_after_as_a_string_of_seconds_is_the_delay = function()
    -- Так его отдаёт клиент HTTP: заголовок Retry-After как пришёл.
    t.assert_equals(delay_for({ retry_after = '0.3' }), 0.3)
    t.assert_equals(delay_for({ retry_after = '120' }), 120)
    t.assert_equals(delay_for({ retry_after = ' 7 ' }), 7)
end

g.test_a_retry_after_that_is_not_seconds_falls_back_to_the_backoff = function()
    local wrong = { 'скоро', 'nan', '-1', -1, 0 / 0, 'Wed, 21 Oct 2015 07:28:00 GMT', true }

    for _, asked in ipairs(wrong) do
        t.assert_equals(delay_for({ retry_after = asked }), 2, tostring(asked))
    end

    t.assert_equals(delay_for('строка — не таблица'), 2)
    t.assert_equals(delay_for({ message = 'без просьбы' }), 2)
end

g.test_an_endless_retry_after_is_cut_to_the_ceiling = function()
    t.assert_equals(delay_for({ retry_after = math.huge }), 3153600000)
    t.assert_equals(delay_for({ retry_after = 'inf' }), 3153600000)
    t.assert_equals(delay_for({ retry_after = 3153600001 }), 3153600000)
end

g.test_the_reason_of_a_table_without_a_message_is_its_tostring = function()
    t.assert_equals(outcome.text('строка'), 'строка')
    t.assert_equals(outcome.text({ retry_after = 1, message = 'подождите' }), 'подождите')
    t.assert_str_contains(outcome.text({ retry_after = 1 }), 'table: ')
    t.assert_str_contains(outcome.text({ message = 7 }), 'table: ')
    t.assert_equals(outcome.text(nil), 'nil')
    t.assert_equals(outcome.text(42), '42')
end

g.test_verdict_names = function()
    t.assert_equals({ outcome.ACK, outcome.RETRY, outcome.BURY }, { 'ack', 'retry', 'bury' })
end

g.test_a_delivery_above_the_ceiling_is_refused_before_the_handler = function()
    local policy = helper.policy({ max_attempts = 3 })

    t.assert_equals(outcome.refusal({ attempt = 3, body = 1 }, policy), nil)
    t.assert_equals(
        outcome.refusal({ attempt = 4, body = 1 }, policy),
        'выдач 4 при потолке 3: прежние выдачи итога не вернули'
    )
end

g.test_a_body_out_of_shape_is_refused_before_the_handler = function()
    local policy = helper.policy(nil)

    t.assert_equals(
        outcome.refusal({ attempt = 1, body = 'семь' }, policy, NUMBER),
        'тело не по форме: : число'
    )
    t.assert_equals(outcome.refusal({ attempt = 1, body = 7 }, policy, NUMBER), nil)
    t.assert_equals(outcome.refusal({ attempt = 1, body = 'семь' }, policy), nil)
end
