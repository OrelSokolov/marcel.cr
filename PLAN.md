# План и статус порта marcel.cr

Цель: порт гема marcel 2.1.0 (Ruby) на Crystal с идентичными результатами
определения MIME-типов. Оракул — `oracle/marcel-2.1.0` (gem) и `oracle/repo`
(репозиторий с тестами); фикстуры идентичны (`spec/fixtures`).

## Архитектура

- `src/marcel.cr` — входная точка.
- `src/marcel/tables.cr` — сгенерированные таблицы (EXTENSIONS, TYPE_EXTS,
  TYPE_ALIASES, TYPE_PARENTS, ROOT_XML, MAGIC); генератор —
  `script/generate_tables.rb`, дампит pre-definitions состояние гема.
- `src/marcel/magic.cr` — `Marcel::Magic`, `MagicRule`, `MagicEntry`,
  реестр + мутации (add/remove/canonicalize), побайтовое сопоставление.
- `src/marcel/magic/definitions.cr` — HTML/XHTML magic из definitions.rb
  (HTML — /imn, XHTML — /xmn, регистрозависимый).
- `src/marcel/magic/xml.cr` — уточнение XML по корневому элементу.
- `src/marcel/magic/zip.cr` — уточнение ZIP/OOXML по central directory.
- `src/marcel/mime_type.cr` — `MimeType.for` и разбор declared type.
- `src/marcel/mime_type/definitions.cr` — переименования из definitions.rb.

## Ключевые решения порта

- PCRE2 в Crystal всегда UTF|UCP: Ruby-семантика `/n` («любой байт»)
  выражается диапазоном до U+10FFFF + флагом `Regex::Options::MATCH_INVALID_UTF`
  (совпадения сквозь невалидные последовательности запрещены, но до них —
  разрешены, без ArgumentError). Для табличных регэкспов в `magic.cr`
  субъект скрабится (`String#scrub`) перед матчем.
- `io_seek`: отрицательные смещения требуют `io.responds_to?(:size)` (аналог
  Ruby `respond_to?(:size)`); seek за конец `IO::Memory` обрабатывается как EOF
  (IndexError от `IO::Memory#read` гасится).
- `by_path` не проверяет кодировку всего пути — только расширение (как Ruby);
  NUL-байты отклоняются явно.
- ZIP64-локатор — 18-байтовая запись (`unpack("VQ<V")` в zip.rb: total disks
  u16), не стандартные 20.
- Транскодирование XML-кодировок — `Crystal::Iconv`; replace-режим
  (invalid/undef → U+FFFD) реализован собственным циклом.
- `canonicalize`/`extend` принимают позиционные аргументы (`instead_of`),
  magic-правила — `Array(MagicRule)`, а не кортежи Ruby.

## Тесты и верификация

- `spec/*_spec.cr` — порт тестового набора гема (639 примеров): magic,
  extension, name, declared_type, html_magic, xml_sniffing, zip_sniffing,
  magic_and_name/declared_type, illustrator, mime_type.
- `spec/oracle_cross_check_spec.cr` + `spec/oracle_expected.yml` — 525 кейсов
  с эталонными ответами Ruby-гема (генерация: `ruby
  script/generate_oracle_expected.rb`).
- Не переносились (Ruby-специфика): `package_test.rb` (упаковка гема),
  `generate_tables_test.rb` (тест Ruby-генератора таблиц через Nokogiri),
  тесты Pathname/ObjectStore/Rack-обёрток и frozen-string предупреждений.

Статус: `crystal spec` — 1164 примера, 0 падений.
