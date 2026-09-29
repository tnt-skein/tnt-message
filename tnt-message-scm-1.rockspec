rockspec_format = '3.0'

package = 'tnt-message'
version = 'scm-1'

source = {
    url = 'git+https://github.com/tnt-skein/tnt-message.git',
    branch = 'main',
}

description = {
    summary = 'Общая часть договора очереди Tarantool: конверт, тело, приговор обработчику, крюки',
    detailed = [[
        То, что у очередей сообщений общее и должно исполняться одним
        кодом: очередь в спейсах, шина внутри узла, ящик исходящих
        и клиенты брокеров обещают обработчику тот же конверт, те же
        настройки отправки и тот же итог, и обещание держится, только пока
        его не пишет каждый своими словами.

        Конверт { id, name, body, headers, key, attempt, created }
        с ULID отправителя и заголовками контекста. Проверка настроек
        отправки по признакам очереди: незнакомая настройка и настройка,
        которой очередь не умеет, — исключение на строке вызывающего.
        Проверка тела: простые данные, вложенность не глубже 100 таблиц
        и не больше 10 000 значений, считая каждую ссылку так, как её
        запишет кодек, — обход списком, конечный и быстрый на любом теле.

        Приговор обработчику: значение — подтвердить, nil, err — вернуть
        с отсрочкой retry_after (числом или строкой секунд) либо растущим
        отступом, последняя выдача и retriable == false — зарыть. Область
        обработчика — контекст отправителя из заголовков и свой request_id,
        крюки отправки и обработки по пакету — для трассы и замеров.

        Ряды метрик договора в реестре встроенного metrics — одни у всех
        очередей: message_sent_total, message_send_failures_total по роду
        отказа, message_handled_total по итогу, message_expired_total,
        message_worker_failures_total, гистограмма ожидания первой выдачи
        message_wait_seconds и глубина message_depth по состоянию, которую
        собирают источники пакетов и складывают по назначению.

        Зависит от tnt-must (проверки аргументов), tnt-context (заголовки
        и область контекста), tnt-id (ULID), tnt-clock (время отправки),
        tnt-log (записи о броске обработчика и сорвавшемся крюке),
        tnt-metrics (ряды) и tnt-external (подмена часов ожидания
        в проверках). Покрытие строк и убитых мутантов — 100 %.
    ]],
    homepage = 'https://github.com/tnt-skein/tnt-message',
    issues_url = 'https://github.com/tnt-skein/tnt-message/issues',
    maintainer = 'tnt-skein',
    license = 'MIT',
    labels = { 'tarantool', 'queue', 'messaging', 'envelope', 'retry', 'metrics' },
}

dependencies = {
    'lua >= 5.1',
    -- Проверки настроек и имён на строке вызывающего.
    'tnt-must',
    -- Заголовки контекста в конверте и область контекста обработчика.
    'tnt-context',
    -- Опознаватель ULID сообщения и запроса обработчика.
    'tnt-id',
    -- Стенное время отправки.
    'tnt-clock',
    -- Записи о броске обработчика и сорвавшемся крюке.
    'tnt-log',
    -- Ряды договора в реестре встроенного metrics.
    'tnt-metrics',
    -- Подмена стенных часов ожидания в проверках.
    'tnt-external',
}

build = {
    type = 'builtin',
    modules = {
        ['tnt.message'] = 'tnt/message.lua',
        ['tnt.message.body'] = 'tnt/message/body.lua',
        ['tnt.message.envelope'] = 'tnt/message/envelope.lua',
        ['tnt.message.hook'] = 'tnt/message/hook.lua',
        ['tnt.message.options'] = 'tnt/message/options.lua',
        ['tnt.message.outcome'] = 'tnt/message/outcome.lua',
        ['tnt.message.scope'] = 'tnt/message/scope.lua',
        ['tnt.message.series'] = 'tnt/message/series.lua',
    },
}
