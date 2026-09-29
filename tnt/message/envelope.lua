--- Конверт сообщения: одна таблица у всех очередей договора.
---
--- `{ id, name, body, headers, key, attempt, created }` — обработчик
--- получает её одинаковой, на какой бы очереди он ни стоял, и переезжает
--- с очереди на очередь без правки.
---
--- **Опознаватель ставит отправитель**, а не очередь: номер задачи
--- в спейсе после опустошения начинается заново, у брокера номер доставки
--- принадлежит каналу, а смещение повторной записи другое. Номер,
--- по которому получатель отсёк бы повтор, через минуту принадлежал бы
--- другому сообщению. ULID несёт время в старших битах: по нему видно,
--- когда сообщение родилось, а сортировка по нему — сортировка по времени.
---
--- **Контекст едет заголовками**: `context.export()` в миг отправки,
--- до любой уступки, поверх — заголовки вызывающего, они главнее.

local clock = require('tnt.clock')
local context = require('tnt.context')
local id = require('tnt.id')

local Module = {}

---@class TntMessage Конверт: один вид у всех очередей договора
---@field id string ULID, его ставит отправитель
---@field name string Назначение: очередь, тема, имя события
---@field body any Тело — простые данные
---@field headers table<string, string> Заголовки: контекст отправителя и свои
---@field key string|nil Ключ порядка
---@field attempt integer Номер выдачи: 0 до первой, 1 на первой
---@field created number Стенное время отправки, секунды
---@field foreign boolean|nil Чужое содержимое очереди, завёрнутое получателем

--- Заголовки сообщения: контекст этого мига и свои поверх.
---@param own table<string, string>|nil Заголовки вызывающего
---@return table<string, string>
function Module.headers(own)
    local headers = context.export()

    for name, value in pairs(own or {}) do
        headers[name] = value
    end

    return headers
end

--- Собирает конверт в миг отправки.
---@param name string Назначение
---@param body any Тело
---@param opts TntMessageSendOptions Проверенные настройки отправки
---@return TntMessage
function Module.new(name, body, opts)
    return {
        id = opts.id or id.ulid(),
        name = name,
        body = body,
        headers = Module.headers(opts.headers),
        key = opts.key,
        attempt = 0,
        created = clock.realtime(),
    }
end

--- Отказы формы одной строкой, по порядку мест: их читает и человек
--- в журнале, и тот, кто поймал исключение отправки.
---@param errors table<string, string> Место → текст отказа
---@return string
function Module.listed(errors)
    local lines = {}

    for place, text in pairs(errors) do
        table.insert(lines, ('%s: %s'):format(place, text))
    end

    table.sort(lines)

    return table.concat(lines, '; ')
end

--- Сверяет тело с формой `tnt-data`, названной при объявлении очереди.
---
--- Негодное тело при отправке — исключение: это данные самого приложения.
--- Пустая форма ничего не сверяет.
---@param shape table|nil Форма: `from(body)` отдаёт значение либо `nil, errors`
---@param body any
---@param where string Куда отправляли — «очереди mail», «теме orders»
---@param level integer Уровень вины в кадрах вызывающего эту функцию
function Module.conform(shape, body, where, level)
    if shape == nil then
        return
    end

    local _, errors = shape.from(body)

    if errors ~= nil then
        error(('тело для %s не по форме: %s'):format(where, Module.listed(errors)), level + 1)
    end
end

return Module
