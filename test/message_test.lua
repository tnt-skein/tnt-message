--- Фасад: части пакета под одним именем.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local message = helper.message

local g = t.group('tnt.message')

g.test_the_facade_gives_the_parts_as_they_are = function()
    t.assert_is(message.options, helper.options.check)
    t.assert_is(message.features, helper.options.features)
    t.assert_is(message.body, helper.body.check)
    t.assert_is(message.explain, helper.body.explain)
    t.assert_is(message.envelope, helper.envelope.new)
    t.assert_is(message.headers, helper.envelope.headers)
    t.assert_is(message.listed, helper.envelope.listed)
    t.assert_is(message.conform, helper.envelope.conform)
    t.assert_is(message.policy, helper.outcome.policy)
    t.assert_is(message.decide, helper.outcome.decide)
    t.assert_is(message.text, helper.outcome.text)
    t.assert_is(message.refusal, helper.outcome.refusal)
    t.assert_is(message.hooks, helper.hook.of)
    t.assert_is(message.caught, helper.scope.caught)
    t.assert_is(message.invoker, helper.scope.invoker)
    t.assert_is(message.judge, helper.scope.judge)
end

g.test_the_facade_names_the_limits_verdicts_and_kinds = function()
    t.assert_equals(message.MAX_SECONDS, 3153600000)
    t.assert_equals({ message.MAX_DEPTH, message.MAX_VALUES }, { 100, 10000 })
    t.assert_equals({ message.ACK, message.RETRY, message.BURY }, { 'ack', 'retry', 'bury' })
    t.assert_equals({ message.SEND, message.HANDLE }, { 'send', 'handle' })
end

g.test_a_wrong_body_through_the_facade_blames_the_caller = function()
    helper.assert_blamed({
        {
            function()
                message.body(helper.deep(126), 1)
            end,
            'тело — вложенность глубже 100 таблиц',
        },
        {
            function()
                message.options({ delay = 1 }, { delay = false }, 1)
            end,
            'настройки отправки: «delay» — эта очередь не умеет',
        },
    })
end
