--- Область обработчика: контекст отправителя, свой опознаватель запроса,
--- крюки обработки, бросок обработчика и приговор.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local context = helper.context
local scope = helper.scope

--- Список крюков проверок: свой, чтобы не задеть списки пакетов очередей.
local hooks = helper.hook.of('tnt.message.scope')

--- Журнал пакета очереди, куда пишется бросок обработчика.
local log = helper.log.new('tnt.message.scope')

local g = t.group('tnt.message.scope')

-- Журнал — первым: запись о снятии крюков проверке не нужна.
g.before_each(function()
    helper.journal.forget()
    helper.forget_hooks(hooks)
end)

g.after_all(function()
    helper.journal.release()
    helper.forget_hooks(hooks)
end)

--- Выданное сообщение.
---@param headers table<string, string>|nil
---@return TntMessage
local function delivered(headers)
    return {
        id = '01J0000000000000000000000X',
        name = 'mail',
        body = { to = 'a@example.org' },
        headers = headers or {},
        attempt = 2,
        created = 0,
    }
end

--- Приговор обработчику при настройках по умолчанию.
---@param message TntMessage
---@param handler fun(message: TntMessage): any, any
---@return string verdict
---@return any extra
local function judge(message, handler)
    return scope.judge(hooks, log, message, helper.policy({ max_attempts = 2 }), scope.invoker(handler))
end

g.test_the_handler_runs_in_the_context_of_the_sender = function()
    local seen = nil

    local verdict = judge(delivered({ ['x-request-id'] = 'r-7' }), function(message)
        seen = { request_id = context.get('request_id'), body = message.body }
    end)

    t.assert_equals(verdict, 'ack')
    t.assert_equals(seen, { request_id = 'r-7', body = { to = 'a@example.org' } })
    t.assert_equals(
        context.get('request_id'),
        nil,
        'область кончилась вместе с обработчиком'
    )
end

g.test_without_a_request_id_the_message_gets_its_own = function()
    local first, second

    judge(delivered(), function()
        first = context.get('request_id')
    end)
    judge(delivered(), function()
        second = context.get('request_id')
    end)

    t.assert_equals(#first, 26)
    t.assert_not_equals(first, second)
end

g.test_the_hooks_wrap_the_handler_with_the_envelope = function()
    local seen = {}

    hooks.set('трасса', function(call, proceed)
        table.insert(seen, { kind = call.kind, name = call.name, id = call.message.id })
        table.insert(seen, context.get('request_id'))

        return proceed()
    end)

    judge(delivered({ ['x-request-id'] = 'r-7' }), function()
        table.insert(seen, 'обработчик')
    end)

    t.assert_equals(seen, {
        { kind = 'handle', name = 'mail', id = '01J0000000000000000000000X' },
        'r-7',
        'обработчик',
    })
end

g.test_a_refusal_of_the_handler_is_judged = function()
    t.assert_equals(
        { judge(delivered(), function()
            return nil, 'занято'
        end) },
        { 'bury', 'попыток 2 из 2: занято' }
    )
    t.assert_equals({
        judge(delivered(), function()
            return nil, { retriable = false, message = 'негодное' }
        end),
    }, { 'bury', 'негодное' })
end

g.test_a_raised_handler_is_written_with_its_stack_and_judged_by_its_text = function()
    local verdict, reason = judge(delivered({ ['x-request-id'] = 'r-7' }), function()
        error('деление на ноль', 0)
    end)

    t.assert_equals({ verdict, reason }, { 'bury', 'попыток 2 из 2: деление на ноль' })

    local found = helper.journal.find('обработчик сообщения бросил')

    t.assert_equals(found.level, 'error')
    t.assert_equals(found.module, 'tnt.message.scope')
    t.assert_equals(found.record.fields.destination, 'mail')
    t.assert_equals(found.record.fields.id, '01J0000000000000000000000X')
    t.assert_equals(found.record.fields.attempt, 2)
    t.assert_equals(found.record.fields.err, 'деление на ноль')
    t.assert_str_contains(found.record.fields.traceback, 'scope_test.lua')
    t.assert_equals(found.record.fields.body, nil, 'тело в журнал не пишется')
end

g.test_a_thrown_table_keeps_its_fields_for_the_verdict = function()
    local verdict, reason = judge(delivered(), function()
        error({ retriable = false, message = 'брошено таблицей' })
    end)

    t.assert_equals({ verdict, reason }, { 'bury', 'брошено таблицей' })
end

g.test_a_handler_that_did_well_is_not_written_about = function()
    judge(delivered(), function()
        return true
    end)

    t.assert_equals(helper.journal.records(), {})
end

g.test_an_invoke_of_the_package_is_taken_as_it_is = function()
    local verdict, reason = scope.judge(hooks, log, delivered(), helper.policy(nil), function(message)
        return false, scope.caught(message.name .. ': своё исполнение')
    end)

    t.assert_equals({ verdict, reason }, { 'retry', 2 })
    t.assert_equals(
        helper.journal.find('обработчик сообщения бросил').record.fields.err,
        'mail: своё исполнение'
    )
end

g.test_caught_keeps_what_was_thrown_and_the_stack = function()
    local ok, caught = xpcall(function()
        error('сбой', 0)
    end, scope.caught)

    ---@cast caught TntMessageCaught
    t.assert_equals(ok, false)
    t.assert_equals(caught.err, 'сбой')

    -- Стек снят с места броска: первым кадром `error`, а не сам ловец
    -- и не то, что лежит под местом броска.
    t.assert_str_matches(caught.traceback, "\nstack traceback:\n\t%[C%]: in function 'error'\n.*")
end
