# tnt-message

Общая часть договора очереди для Tarantool: конверт сообщения, проверка
настроек отправки и тела, приговор обработчику, область обработчика,
крюки отправки и обработки и ряды метрик. Очередь пишет своё — взятие и итог у рока
или брокера, — а общее берёт отсюда, и обработчик переезжает с одной
очереди на другую без правки.

```lua
local message = require('tnt.message')

function Jobs:send(body, opts)
    local given = message.options(opts, FEATURES, 2)

    message.body(body, 2)

    return hooks.around({ kind = message.SEND, name = self.name }, function()
        return self:put(message.envelope(self.name, body, given))
    end)
end

-- в работнике: контекст отправителя, крюки, обработчик, приговор
local verdict, extra = message.judge(hooks, log, envelope, policy, message.invoker(handler))
```

Зависит от `tnt-must`, `tnt-context`, `tnt-id`, `tnt-clock`, `tnt-log`,
`tnt-metrics` и `tnt-external`.

## Зачем

Очереди с общим договором обещают обработчику одно и то же: тот же
конверт, те же настройки, тот же итог. Копии этой общей части, написанные
каждой очередью своими словами, расходятся молча — одно тело одна очередь
принимает, другая отвергает, — и расхождения не видит ни одна проверка.
Здесь общее проверено однажды:

- **конверт** `{ id, name, body, headers, key, attempt, created }` с ULID
  отправителя и заголовками контекста;
- **настройки отправки** по признакам очереди: незнакомая настройка
  и настройка, которой очередь не умеет, — исключение с причиной;
- **тело** — простые данные, не глубже 100 таблиц и не больше 10 000
  значений, считая каждую ссылку так, как её запишет кодек;
- **приговор** обработчику: значение — подтвердить, `nil, err` —
  вернуть с отсрочкой `retry_after` (числом или строкой секунд) или
  отступом, последняя выдача и `retriable == false` — зарыть;
- **область** обработчика: контекст отправителя и свой `request_id`;
- **крюки** `send` и `handle` по пакету — для трассы и замеров;
- **ряды метрик** `message_*` — одни у всех очередей: отправлено, отказы
  по роду, итог обработки, истекло, сбои работника, ожидание первой
  выдачи и глубина, которую складывают источники пакетов
  (`tnt.message.series`).

## Установка

```sh
tt rocks install tnt-message --server=https://tnt-skein.github.io/rocks
```

Или из исходников:

```sh
git clone https://github.com/tnt-skein/tnt-message.git
cd tnt-message && tt rocks make
```

## Как пользоваться

| Что | Функции |
|---|---|
| Конверт | `envelope`, `headers` |
| Настройки отправки | `options`, `features` |
| Тело | `body`, `explain`, `MAX_DEPTH`, `MAX_VALUES` |
| Форма тела | `conform`, `listed` |
| Получатель и приговор | `policy`, `decide`, `text`, `refusal` |
| Область обработчика | `judge`, `invoker`, `caught` |
| Крюки | `hooks(label)` → `set`, `names`, `around` |

Подробно, с примерами и тем, чем пришлось поступиться, — в документе.

## Проверки

```sh
make deps
make check
make mutants-all
```

Проверок 90, все в процессе; покрытие строк — 100 %, убитых мутантов —
100 % (318 мутантов в семи модулях, фасад мутировать нечего).

## Документ

[docs/message.md](docs/message.md)

## Лицензия

MIT
