# marcel.cr

Порт гема [marcel](https://github.com/rails/marcel) 2.1.0 (Ruby) на Crystal с API 1:1.

Определение MIME-типа по magic-байтам, имени/расширению файла и объявленному
типу: уточнение XML по корневому элементу и ZIP/OOXML по central directory.
Таблицы сгенерированы из оригинального `lib/marcel/tables.rb` (Tika +
custom.xml), поэтому результаты идентичны Ruby-гему.

## Установка

1. Добавьте шард в `shard.yml`:

```yaml
dependencies:
  marcel:
    github: your-github/marcel.cr
```

2. Запустите `shards install`.

## Использование

```crystal
require "marcel"

Marcel::MimeType.for(Path["file.gif"])                       # => "image/gif"
Marcel::MimeType.for(IO::Memory.new(File.read("file.docx"))) # => "application/vnd..."
Marcel::MimeType.for(name: "file.xml")                       # => "application/xml"
Marcel::MimeType.for(extension: "pdf")                       # => "application/pdf"
Marcel::MimeType.for(Path["book.mov"), name: "book.m4v",
                     declared_type: "video/mp4")             # приоритет: magic → имя → тип
```

`MimeType.for` принимает `Path` (файл), `IO` (содержимое), `String`
(содержимое) или `nil`, плюс необязательные подсказки `name`, `extension`,
`declared_type`. Более поздний кандидат используется, только если он более
специфичен, чем уже найденный тип. Если тип определить не удалось, возвращается
`application/octet-stream`.

Низкоуровневый API:

```crystal
Marcel::Magic.by_path("image.png")    # => Marcel::Magic?
Marcel::Magic.by_extension("png")     # => Marcel::Magic?
Marcel::Magic.by_type("image/png")    # => Marcel::Magic?
Marcel::Magic.by_magic(io)            # медленно: анализ содержимого
Marcel::Magic.all_by_magic(io)        # все совпавшие типы

magic = Marcel::Magic.new("text/html")
magic.text?   # => true
magic.image?  # => false
magic.extensions
magic.child_of?("text/plain")

# Расширение реестра (мутации глобальны, как в Ruby-геме):
Marcel::Magic.add("application/x-my-thing", extensions: "mtg",
                  parents: "application/json")
Marcel::Magic.remove("application/x-my-thing")
Marcel::Magic.canonicalize("application/x-my-thing", "text/x-my-thing")
Marcel::MimeType.extend("application/x-my-thing", extensions: %w(mtg))
```

## Отличия от Ruby-версии

- `Path` вместо `Pathname`; `String`-аргумент трактуется как содержимое, не путь.
- Регэкспы magic-правил исполняются на PCRE2 (всегда UTF-режим), а не Onigmo
  с флагом `/n`; семантика байтов воспроизведена (см. `src/marcel/magic/xml.cr`).
- Не-UTF-8 кодировки XML-документов транскодируются через iconv.

## Разработка

```
crystal spec                # порт тестового набора гема (639 примеров)
                            # + кросс-чек с оракулом (525 примеров)
```

Кросс-чек сравнивает порт с эталонными ответами Ruby-гема
(`spec/oracle_expected.yml`). Для регенерации эталона нужен системный Ruby:

```
ruby script/generate_oracle_expected.rb
```

`script/generate_tables.rb` перегенерирует `src/marcel/tables.cr` из
оракул-гема (обычно не нужен — таблицы уже сгенерированы).

## Лицензия

Как и оригинальный гем — MIT и Apache-2.0. Порт включает код marcel
(Copyright © Tom Ward и участники проекта) и mimemagic (Copyright © 2011
Daniel Mendler, MIT).
