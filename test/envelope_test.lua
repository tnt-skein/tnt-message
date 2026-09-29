--- Конверт сообщения: сборка, заголовки контекста, отказы формы.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local context = helper.context
local envelope = helper.envelope

local g = t.group('tnt.message.envelope')

--- Форма `tnt-data`: пропускает таблицу с числовым `order`.
local ORDER = {
    from = function(value)
        if type(value) == 'table' and type(value.order) == 'number' then
            return value
        end

        return nil,
            { order = 'обязательное число', ['address.city'] = 'должно быть строкой' }
    end,
}

g.test_an_envelope_carries_the_context_of_the_sender = function()
    local message = context.run({ request_id = 'r-7' }, function()
        return envelope.new('mail', { to = 'a@example.org' }, { key = 'a' })
    end)

    t.assert_equals(message.name, 'mail')
    t.assert_equals(message.body, { to = 'a@example.org' })
    t.assert_equals(message.headers, { ['x-request-id'] = 'r-7' })
    t.assert_equals(message.key, 'a')
    t.assert_equals(message.attempt, 0)
    t.assert_equals(#message.id, 26)
    t.assert_almost_equals(message.created, require('clock').realtime(), 1)
end

g.test_own_headers_win_over_the_carried_ones = function()
    local message = context.run({ request_id = 'r-7' }, function()
        return envelope.new('mail', 'тело', { headers = { ['x-request-id'] = 'r-8', own = 'да' } })
    end)

    t.assert_equals(message.headers, { ['x-request-id'] = 'r-8', own = 'да' })
end

g.test_a_ready_identifier_is_taken_as_it_is = function()
    local message = envelope.new('mail', 'тело', { id = '01J0000000000000000000000X' })

    t.assert_equals(message.id, '01J0000000000000000000000X')
    t.assert_equals(message.headers, {})
    t.assert_equals(message.key, nil)
end

g.test_two_envelopes_get_different_identifiers = function()
    t.assert_not_equals(envelope.new('mail', 1, {}).id, envelope.new('mail', 2, {}).id)
end

g.test_headers_are_the_context_of_the_moment_and_own_ones = function()
    t.assert_equals(envelope.headers(nil), {})
    t.assert_equals(envelope.headers({ own = 'да' }), { own = 'да' })
    t.assert_equals(
        context.run({ request_id = 'r-9' }, envelope.headers, { own = 'да' }),
        { ['x-request-id'] = 'r-9', own = 'да' }
    )
end

g.test_shape_complaints_are_listed_in_place_order = function()
    t.assert_equals(
        envelope.listed({
            name = 'обязательное поле',
            ['address.city'] = 'должно быть строкой',
        }),
        'address.city: должно быть строкой; name: обязательное поле'
    )
    t.assert_equals(envelope.listed({}), '')
end

g.test_a_body_out_of_shape_is_raised_at_the_caller = function()
    helper.assert_blamed({
        {
            function()
                envelope.conform(ORDER, { order = 'семь' }, 'очереди mail', 1)
            end,
            'тело для очереди mail не по форме: address.city: должно быть строкой; order: обязательное число',
        },
    })
end

g.test_a_body_in_shape_and_no_shape_raise_nothing = function()
    t.assert_equals(envelope.conform(ORDER, { order = 7 }, 'очереди mail', 1), nil)
    t.assert_equals(envelope.conform(nil, 'что угодно', 'очереди mail', 1), nil)
end
