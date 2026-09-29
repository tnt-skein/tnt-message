--- Настройки отправки: ключи, границы, заголовки и признаки очереди.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local options = helper.options

local g = t.group('tnt.message.options')

--- Признаки очереди, которая не умеет ни ключа, ни отсрочки.
local PLAIN = { key = false, delay = false, ttl = true, priority = true }

--- Настройки у очереди, которая умеет всё.
---@param opts any
---@return TntMessageSendOptions
local function check(opts)
    return options.check(opts, {}, 1)
end

g.test_options_default_to_an_empty_table = function()
    t.assert_equals(check(nil), {})
end

g.test_the_given_settings_pass_through = function()
    local given = {
        key = 'a',
        delay = 3153600000,
        ttl = 3153599999,
        priority = 0,
        id = 'x',
        timeout = 3,
        headers = { own = 'да' },
    }

    t.assert_equals(check(given), given)
    t.assert_equals(options.MAX_SECONDS, 3153600000)
end

g.test_unknown_and_wrong_settings_are_raised_at_the_caller = function()
    helper.assert_blamed({
        {
            function()
                check(helper.wrong('всё'))
            end,
            'настройки отправки — таблица, а не строка',
        },
        {
            function()
                check({ priorty = 1 })
            end,
            'настройки отправки: ключа «priorty» нет, есть delay, headers, id, key, priority, timeout, ttl',
        },
        {
            function()
                check({ delay = -1 })
            end,
            'настройки отправки.delay — число от 0 до 3153600000, а не -1',
        },
        {
            function()
                check({ delay = 3153600001 })
            end,
            'настройки отправки.delay — число от 0 до 3153600000, а не 3153600001',
        },
        {
            function()
                check({ ttl = 0 })
            end,
            'настройки отправки.ttl — число больше 0, а не 0',
        },
        {
            function()
                check({ ttl = 3153600000 })
            end,
            'настройки отправки.ttl — число меньше 3153600000, а не 3153600000',
        },
        {
            function()
                check({ priority = -1 })
            end,
            'настройки отправки.priority — число не меньше 0, а не -1',
        },
        {
            function()
                check({ priority = 0.5 })
            end,
            'настройки отправки.priority — целое число, а не 0.5',
        },
        {
            function()
                check({ timeout = 0 })
            end,
            'настройки отправки.timeout — число больше 0, а не 0',
        },
        {
            function()
                check({ key = '' })
            end,
            'настройки отправки.key — непустая строка, а не пустая',
        },
        {
            function()
                check({ id = helper.wrong(7) })
            end,
            'настройки отправки.id — непустая строка, а не число',
        },
    })
end

g.test_header_names_are_lowercase_and_values_are_strings = function()
    helper.assert_blamed({
        {
            function()
                check({ headers = { ['X-Request-Id'] = 'r-1' } })
            end,
            'имя заголовка — строка по образцу ^[a-z0-9][a-z0-9%-]*$, а не «X-Request-Id»',
        },
        {
            function()
                check({ headers = { ['x-request-id'] = helper.wrong(7) } })
            end,
            'заголовок x-request-id — строка, а не число',
        },
    })
end

g.test_a_setting_the_queue_cannot_do_says_why = function()
    local how = { unable = { key = 'порядка по ключу брокер не обещает' } }

    helper.assert_blamed({
        {
            function()
                options.check({ key = 'a' }, PLAIN, 1, how)
            end,
            'настройки отправки: «key» — порядка по ключу брокер не обещает',
        },
        {
            function()
                options.check({ delay = 1 }, PLAIN, 1, how)
            end,
            'настройки отправки: «delay» — эта очередь не умеет',
        },
        {
            function()
                options.check({ delay = 1 }, PLAIN, 1, { cannot = 'отправитель не умеет' })
            end,
            'настройки отправки: «delay» — отправитель не умеет',
        },
        {
            function()
                options.check({ delay = 1 }, PLAIN, 1, { what = 'настройки записи' })
            end,
            'настройки записи: «delay» — эта очередь не умеет',
        },
    })
end

g.test_the_feature_is_checked_before_the_kind_of_the_value = function()
    helper.assert_blamed({
        {
            function()
                options.check({ delay = 'скоро' }, PLAIN, 1)
            end,
            'настройки отправки: «delay» — эта очередь не умеет',
        },
    })
end

g.test_of_two_settings_the_queue_cannot_do_the_key_is_named = function()
    helper.assert_blamed({
        {
            function()
                options.check({ delay = 1, key = 'a' }, PLAIN, 1)
            end,
            'настройки отправки: «key» — эта очередь не умеет',
        },
    })
end

g.test_what_the_queue_can_do_passes = function()
    t.assert_equals(options.check({ ttl = 5, priority = 1 }, PLAIN, 1), { ttl = 5, priority = 1 })
    t.assert_equals(options.check({ key = 'a' }, { key = true }, 1), { key = 'a' })
end

g.test_a_feature_the_queue_did_not_name_is_not_refused = function()
    t.assert_equals(options.check({ key = 'a', delay = 1 }, { ttl = false }, 1), { key = 'a', delay = 1 })
end

g.test_features_are_checked_for_the_names_given = function()
    helper.assert_blamed({
        {
            function()
                options.features(
                    { atomic = true },
                    { 'atomic' },
                    { atomic = false },
                    1,
                    { what = 'настройки получателя' }
                )
            end,
            'настройки получателя: «atomic» — эта очередь не умеет',
        },
    })

    t.assert_equals(options.features(nil, { 'atomic' }, { atomic = false }, 1, {}), nil)
    t.assert_equals(options.features({ atomic = false }, { 'key' }, { atomic = false }, 1, {}), nil)
end
