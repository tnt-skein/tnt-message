--- Общая часть договора очереди: конверт, настройки отправки и признаки,
--- тело, приговор обработчику, область обработчика и крюки.
---
---     local message = require('tnt.message')
---
---     local hooks = message.hooks('tnt.jobs')
---
---     function Jobs:send(body, opts)
---         local given = message.options(opts, FEATURES, 2)
---
---         message.body(body, 2)
---
---         return hooks.around({ kind = message.SEND, name = self.name }, function()
---             return self:put(message.envelope(self.name, body, given))
---         end)
---     end
---
---     -- в работнике: область, крюки, обработчик, приговор
---     local verdict, extra = message.judge(hooks, log, envelope, policy, invoke)
---
--- **Зачем пакет.** Очередь в спейсах, шина внутри узла, ящик исходящих
--- и клиенты брокеров обещают обработчику одно и то же: тот же конверт,
--- те же настройки, тот же итог. Обещание держится, только пока его
--- исполняет один код: копии, написанные каждым пакетом своими словами,
--- расходятся молча — одно и то же тело одна очередь принимает, другая
--- отвергает, — и расхождения не видит ни одна проверка. Здесь то, что
--- у очередей общее, проверяется однажды. У пакета очереди остаётся своё:
--- взятие и итог у рока или брокера, свои признаки и свои тексты отказов.
---
--- Отказов парой здесь нет: всё, что отвергается, — ошибка программиста
--- (незнакомая настройка, настройка, которой очередь не умеет, тело не из
--- простых данных) и бросается на строке того, кто позвал пакет очереди.
--- Своего типа отказа нет тоже: приговор читает отказ обработчика
--- по полям `retriable` и `retry_after`, чей бы он ни был.
---
--- Зависимость от пакета приходит аргументом: журнал пакета очереди,
--- крюки и признаки передаются в вызов, а не берутся из контейнера.

local body = require('tnt.message.body')
local envelope = require('tnt.message.envelope')
local hook = require('tnt.message.hook')
local options = require('tnt.message.options')
local outcome = require('tnt.message.outcome')
local scope = require('tnt.message.scope')

local Module = {}

--- Потолок сроков в секундах — сто лет.
Module.MAX_SECONDS = options.MAX_SECONDS

--- Пределы тела: вложенность таблиц и число значений.
Module.MAX_DEPTH, Module.MAX_VALUES = body.MAX_DEPTH, body.MAX_VALUES

--- Приговоры обработчику.
Module.ACK, Module.RETRY, Module.BURY = outcome.ACK, outcome.RETRY, outcome.BURY

--- Роды обращения, которое оборачивает крюк.
Module.SEND, Module.HANDLE = hook.SEND, hook.HANDLE

--- Проверяет настройки отправки по признакам очереди.
Module.options = options.check

--- Отказывает настройке, которой очередь не умеет, по списку признаков.
Module.features = options.features

--- Проверяет тело: простые данные в пределах либо исключение.
Module.body = body.check

--- Чем тело не годится; `nil` — годится.
Module.explain = body.explain

--- Собирает конверт в миг отправки.
Module.envelope = envelope.new

--- Заголовки контекста этого мига и свои поверх.
Module.headers = envelope.headers

--- Отказы формы одной строкой по порядку мест.
Module.listed = envelope.listed

--- Сверяет тело с формой при отправке.
Module.conform = envelope.conform

--- Проверяет настройки получателя и ставит умолчания.
Module.policy = outcome.policy

--- Приговор обработчику: подтвердить, вернуть с отсрочкой или зарыть.
Module.decide = outcome.decide

--- Текст причины отказа.
Module.text = outcome.text

--- Почему выданное зарывается, не доходя до обработчика.
Module.refusal = outcome.refusal

--- Список крюков пакета по его имени.
Module.hooks = hook.of

--- Обработчик `xpcall`: брошенное и стек отдельно.
Module.caught = scope.caught

--- Исполнение обработчика по умолчанию.
Module.invoker = scope.invoker

--- Область обработчика: контекст, крюки, приговор.
Module.judge = scope.judge

return Module
