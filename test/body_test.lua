--- Тело сообщения: простые данные, кольцо, пределы вложенности и числа
--- значений, место отказа.

local json = require('json')
local msgpack = require('msgpack')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local body = helper.body

local g = t.group('tnt.message.body')

g.test_plain_data_passes = function()
    t.assert_equals(body.explain({ to = 'a@example.org', copies = 2, urgent = true, tags = { 'mail', 'now' } }), nil)
    t.assert_equals(body.explain('строка'), nil)
    t.assert_equals(body.explain(false), nil)
    t.assert_equals(body.explain(-7.5), nil)
    t.assert_equals(body.explain(nil), nil)
    t.assert_equals(body.explain({}), nil)
end

g.test_what_is_not_plain_data_is_named_with_its_place = function()
    local cycle = { name = 'кольцо' }

    cycle.self = cycle

    local cases = {
        { require('uuid').new(), 'тело — простые данные, а не cdata' },
        { { at = require('datetime').new() }, 'тело.at — простые данные, а не cdata' },
        { { send = print }, 'тело.send — простые данные, а не function' },
        { { 1, 2, 0 / 0 }, 'тело.3 — конечное число, а не nan' },
        { math.huge, 'тело — конечное число, а не inf' },
        { { order = { total = -math.huge } }, 'тело.order.total — конечное число, а не -inf' },
        { cycle, 'тело.self — кольцо: таблица лежит сама в себе' },
        {
            { [{ key = 1 }] = 'значение' },
            'тело: ключ — строка или число, а не table',
        },
        { { order = { [true] = 1 } }, 'тело.order: ключ — строка или число, а не boolean' },
        { { [1.5] = 'полтора' }, 'тело: ключ-число — целое, а не 1.5' },
        { { order = { [math.huge] = 1 } }, 'тело.order: ключ-число — целое, а не inf' },
        { { box.NULL }, 'тело.1 — простые данные, а не cdata' },
    }

    for _, case in ipairs(cases) do
        t.assert_equals(body.explain(case[1]), case[2])
    end
end

g.test_integer_keys_of_any_sign_pass = function()
    -- Их JSON пишет строками, а msgpack — числами; это договор называет,
    -- но не отвергает: такой ключ хотя бы ложится в оба кодека.
    t.assert_equals(body.explain({ [0] = 'ноль', [-1] = 'минус', [3] = 'три' }), nil)
end

g.test_a_ring_deeper_down_is_found_on_its_own_path = function()
    local outer = { inner = { list = {} } }

    outer.inner.list[1] = outer.inner

    t.assert_equals(
        body.explain(outer),
        'тело.inner.list.1 — кольцо: таблица лежит сама в себе'
    )
end

g.test_the_same_table_in_two_branches_is_not_a_ring = function()
    local city = { name = 'Тверь' }

    t.assert_equals(body.explain({ from = city, to = city, via = { city, { city } } }), nil)
end

g.test_a_table_left_behind_is_taken_off_the_path = function()
    -- Первая ветка уже пройдена, когда вторая снова ведёт в ту же таблицу:
    -- на пути её нет, и кольцом это не считается.
    local shared = { leaf = true }
    local list = { shared, { { shared } } }

    t.assert_equals(body.explain(list), nil)
end

g.test_a_hundred_tables_deep_pass_and_one_more_is_refused = function()
    t.assert_equals(body.MAX_DEPTH, 100)
    t.assert_equals(body.explain(helper.deep(99)), nil, 'сто таблиц, корень — первая')
    t.assert_equals(body.explain(helper.deep(100)), 'тело — вложенность глубже 100 таблиц')
    t.assert_equals(body.explain({ list = { helper.deep(97) } }), nil, 'две обёртки и 98 таблиц')
    t.assert_equals(
        body.explain({ list = { helper.deep(98) } }),
        'тело — вложенность глубже 100 таблиц'
    )
end

g.test_a_body_the_codecs_cannot_write_is_refused_by_the_depth = function()
    -- Кодеки отказывают на 129-й таблице; тело глубже сотни до них не доходит.
    for _, levels in ipairs({ 127, 128, 150 }) do
        t.assert_equals(
            body.explain(helper.deep(levels)),
            'тело — вложенность глубже 100 таблиц'
        )
    end

    t.assert_error_msg_contains('Too high nest level', msgpack.encode, helper.deep(128))
    t.assert_error_msg_contains('Too high nest level', json.encode, helper.deep(128))
end

g.test_ten_thousand_values_pass_and_one_more_is_refused = function()
    t.assert_equals(body.MAX_VALUES, 10000)
    t.assert_equals(body.explain(helper.wide(9999)), nil, 'список и 9999 чисел — 10000 значений')
    t.assert_equals(body.explain(helper.wide(10000)), 'тело — не больше 10000 значений')
    t.assert_equals(body.explain(helper.wide(20000)), 'тело — не больше 10000 значений')
end

g.test_nested_tables_are_values_too = function()
    local rows = {}

    -- Корень, 4999 строк и по числу в каждой — 9999 значений.
    for index = 1, 4999 do
        rows[index] = { index }
    end

    t.assert_equals(body.explain(rows), nil)

    rows[5000] = { 5000 }

    t.assert_equals(body.explain(rows), 'тело — не больше 10000 значений')
end

g.test_every_reference_is_counted_as_the_codec_writes_it = function()
    local leaf = helper.wide(99)
    local root = {}

    -- Сто ссылок на список из 99 чисел: кодек пишет его сто раз.
    for index = 1, 100 do
        root[index] = leaf
    end

    t.assert_equals(body.explain(root), 'тело — не больше 10000 значений')

    root[100] = nil

    t.assert_equals(
        body.explain(root),
        nil,
        'корень, 99 ссылок и 99 · 99 чисел — 9901 значение'
    )
end

g.test_a_table_shared_on_every_level_is_refused_at_once = function()
    -- Двадцать уровней кодек писал бы миллионом копий: отказ приходит
    -- на десятитысячной ссылке, а не после обхода их всех.
    t.assert_equals(body.explain(helper.shared(20)), 'тело — не больше 10000 значений')
    t.assert_equals(body.explain(helper.shared(16)), 'тело — не больше 10000 значений')
    t.assert_equals(body.explain(helper.shared(12)), 'тело — не больше 10000 значений')
    t.assert_equals(
        body.explain(helper.shared(11)),
        nil,
        '2^12 − 1 ссылок на таблицы и 2^11 листьев'
    )
end

g.test_the_limit_is_met_inside_a_wide_table = function()
    t.assert_equals(body.explain({ helper.wide(300000) }), 'тело — не больше 10000 значений')
end

g.test_a_wrong_body_is_raised_at_the_caller = function()
    helper.assert_blamed({
        {
            function()
                body.check({ send = print }, 1)
            end,
            'тело.send — простые данные, а не function',
        },
        {
            function()
                body.check(helper.deep(126), 1)
            end,
            'тело — вложенность глубже 100 таблиц',
        },
    })
end

g.test_a_good_body_raises_nothing = function()
    t.assert_equals(body.check({ order = 7 }, 1), nil)
end
