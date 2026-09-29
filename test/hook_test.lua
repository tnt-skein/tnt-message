--- Крюки: список пакета, постановка, порядок и то, что сорвавшийся крюк
--- не срывает дела.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local hook = helper.hook

--- Список крюков проверок: свой, чтобы не задеть списки пакетов очередей.
local hooks = hook.of('tnt.message.test')

local g = t.group('tnt.message.hook')

g.before_each(function()
    helper.forget_hooks(hooks)
    helper.journal.forget()
end)

g.after_all(function()
    helper.forget_hooks(hooks)
    helper.journal.release()
end)

--- Обращение отправки для проверок.
local function call()
    return { kind = hook.SEND, name = 'mail' }
end

--- Крюк, который только пропускает дело.
local function passing(_, proceed)
    return proceed()
end

g.test_the_list_of_a_package_is_one_per_process = function()
    t.assert_is(hook.of('tnt.message.test'), hooks)
    t.assert_equals(hooks.label, 'tnt.message.test')
    t.assert_not_equals(hook.of('tnt.message.other'), hooks)
    t.assert_equals({ hook.SEND, hook.HANDLE }, { 'send', 'handle' })
end

g.test_the_lists_of_two_packages_do_not_mix = function()
    local other = hook.of('tnt.message.other')

    hooks.set('первый', passing)

    t.assert_equals(other.names(), {})
    t.assert_equals(hooks.names(), { 'первый' })
end

g.test_hooks_are_named_in_the_order_they_were_set = function()
    hooks.set('первый', passing)
    hooks.set('второй', passing)

    t.assert_equals(hooks.names(), { 'первый', 'второй' })
end

g.test_a_replaced_hook_keeps_its_place = function()
    local seen = {}

    hooks.set('первый', passing)
    hooks.set('второй', passing)
    hooks.set('первый', function(_, proceed)
        table.insert(seen, 'замена')

        return proceed()
    end)

    hooks.around(call(), function() end)

    t.assert_equals(hooks.names(), { 'первый', 'второй' })
    t.assert_equals(seen, { 'замена' })
end

g.test_a_removed_hook_is_not_called_and_a_new_one_goes_last = function()
    local seen = {}

    hooks.set('первый', function()
        table.insert(seen, 'снятый')
    end)
    hooks.set('второй', passing)
    hooks.set('первый', nil)

    hooks.around(call(), function() end)
    hooks.set('первый', passing)

    t.assert_equals(seen, {})
    t.assert_equals(hooks.names(), { 'второй', 'первый' })
end

g.test_removing_a_hook_that_was_never_set_changes_nothing = function()
    hooks.set('второй', passing)
    hooks.set('первый', nil)

    t.assert_equals(hooks.names(), { 'второй' })
end

g.test_wrong_arguments_are_raised_at_the_caller = function()
    helper.assert_blamed({
        {
            function()
                hooks.set('', print)
            end,
            'имя крюка — непустая строка, а не пустая',
        },
        {
            function()
                hooks.set('крюк', helper.wrong(7))
            end,
            'крюк — функция или вызываемая таблица, а не число',
        },
        {
            function()
                hook.of(helper.wrong(nil))
            end,
            'имя пакета — непустая строка, а не nil',
        },
    })
end

g.test_hooks_wrap_the_call_from_outside_in = function()
    local seen = {}

    hooks.set('внешний', function(given, proceed)
        table.insert(seen, 'внешний до ' .. given.kind)

        local first, second = proceed()

        table.insert(seen, 'внешний после')

        return first, second
    end)

    hooks.set('внутренний', function(_, proceed)
        table.insert(seen, 'внутренний до')

        return proceed()
    end)

    local id, err = hooks.around(call(), function()
        table.insert(seen, 'отправка')

        return 'опознаватель', nil
    end)

    t.assert_equals(id, 'опознаватель')
    t.assert_equals(err, nil)
    t.assert_equals(
        seen,
        { 'внешний до send', 'внутренний до', 'отправка', 'внешний после' }
    )
end

g.test_the_call_carries_the_envelope_the_proceed_has_built = function()
    local seen = nil

    hooks.set('трасса', function(given, proceed)
        local answer = proceed()

        seen = given.message

        return answer
    end)

    local given = call()

    hooks.around(given, function()
        given.message = { id = 'конверт' }
    end)

    t.assert_equals(seen, { id = 'конверт' })
end

g.test_proceed_runs_once_even_if_the_hook_calls_it_twice = function()
    local runs = 0

    hooks.set('жадный', function(_, proceed)
        proceed()

        return proceed()
    end)

    local answer = hooks.around(call(), function()
        runs = runs + 1

        return runs
    end)

    t.assert_equals(runs, 1)
    t.assert_equals(answer, 1)
end

g.test_the_hook_sees_the_values_of_proceed_as_they_are = function()
    ---@type table
    local seen

    hooks.set('счётчик', function(_, proceed)
        seen = { n = select('#', proceed()), proceed() }

        return nil
    end)

    hooks.around(call(), function()
        return 'опознаватель', nil, 3
    end)

    t.assert_equals(seen.n, 3, 'ни одного лишнего значения впереди')
    t.assert_equals(seen[1], 'опознаватель')
    t.assert_equals(seen[3], 3)
end

g.test_all_values_of_the_call_reach_the_caller_through_the_hooks = function()
    hooks.set('первый', passing)

    local answer, err, extra = hooks.around(call(), function()
        return nil, 'отказ', 3
    end)

    t.assert_equals({ answer, err, extra }, { nil, 'отказ', 3 })
    t.assert_equals(select('#', hooks.around(call(), function() end)), 0)
end

g.test_a_hook_that_raised_before_proceed_does_not_skip_the_call = function()
    hooks.set('битый', function()
        error('крюк сломан', 0)
    end)

    t.assert_equals(
        hooks.around(call(), function()
            return 'отправлено'
        end),
        'отправлено'
    )

    local found = helper.journal.find('крюк сорвался и пропущен')

    t.assert_equals(found.module, 'tnt.message.test')
    t.assert_equals(found.level, 'warn')
    t.assert_equals(found.record.fields.err, 'крюк сломан')
    t.assert_equals(found.record.fields.hook, 'битый')
    t.assert_equals(found.record.fields.kind, 'send')
    t.assert_equals(found.record.fields.destination, 'mail')
end

g.test_a_hook_that_raised_after_proceed_keeps_the_result = function()
    local runs = 0

    hooks.set('битый', function(_, proceed)
        proceed()

        error('после отправки', 0)
    end)

    t.assert_equals(
        hooks.around(call(), function()
            runs = runs + 1

            return 'отправлено'
        end),
        'отправлено'
    )

    t.assert_equals(runs, 1)
    t.assert_equals(helper.journal.find('крюк сорвался').record.fields.err, 'после отправки')
end

--- Исполняет обращение, которое бросает, под крюками `list` и отдаёт
--- брошенное и сколько раз обращение исполнялось.
---@param thrown any Что бросает обращение
---@param list TntMessageHook[] Крюки по порядку
---@return any err
---@return integer runs
local function thrown_through(thrown, list)
    local runs = 0

    for index, hooked in ipairs(list) do
        hooks.set('крюк ' .. index, hooked)
    end

    local ok, err = pcall(hooks.around, call(), function()
        runs = runs + 1

        error(thrown, 0)
    end)

    t.assert_equals(ok, false)

    return err, runs
end

g.test_a_call_that_raised_through_a_passing_hook_runs_once_and_blames_no_hook = function()
    local thrown = { message = 'отправка бросила' }
    local err, runs = thrown_through(thrown, { passing, passing })

    t.assert_is(err, thrown)
    t.assert_equals(runs, 1)
    t.assert_equals(helper.journal.records(), {})

    -- Текст броска — без приписки места: уходит тем же значением.
    err, runs = thrown_through('отправка бросила', { passing })

    t.assert_equals({ err, runs }, { 'отправка бросила', 1 })
end

g.test_a_call_that_raised_is_raised_whatever_the_hook_did_with_it = function()
    local swallowed = {}

    local err, runs = thrown_through('отправка бросила', {
        function(_, proceed)
            for _ = 1, 2 do
                local _, seen = pcall(proceed)

                table.insert(swallowed, seen)
            end

            return 'мимо'
        end,
    })

    -- Крюк видел бросок при каждом зове, а обращение исполнилось однажды.
    t.assert_equals(swallowed, { 'отправка бросила', 'отправка бросила' })
    t.assert_equals({ err, runs }, { 'отправка бросила', 1 })
    t.assert_equals(helper.journal.records(), {})
end

g.test_a_hook_that_did_not_call_proceed_does_not_cancel_the_call = function()
    hooks.set('молчун', function()
        return 'мимо'
    end)

    t.assert_equals(
        hooks.around(call(), function()
            return 'отправлено'
        end),
        'отправлено'
    )

    t.assert_equals(
        helper.journal.find('крюк сорвался').record.fields.err,
        'крюк не позвал proceed'
    )
end

g.test_a_hook_that_behaved_is_not_written_about = function()
    hooks.set('первый', passing)
    hooks.around(call(), function() end)

    t.assert_equals(helper.journal.records(), {})
end

g.test_a_hook_set_during_a_call_waits_for_the_next_one = function()
    local seen = {}

    hooks.set('ставящий', function(_, proceed)
        hooks.set('поздний', function(_, inner)
            table.insert(seen, 'поздний')

            return inner()
        end)

        return proceed()
    end)

    hooks.around(call(), function() end)

    t.assert_equals(seen, {})

    hooks.around(call(), function() end)

    t.assert_equals(seen, { 'поздний' })
end
