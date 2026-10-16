# marcel.cr

A Crystal port of the [marcel](https://github.com/rails/marcel) 2.1.0 Ruby gem with a 1:1 API.

MIME type detection by magic bytes, file name/extension, and declared type:
XML refinement by root element and ZIP/OOXML refinement by central directory.
The tables are generated from the original `lib/marcel/tables.rb` (Tika +
custom.xml), so results are identical to the Ruby gem.

## Installation

1. Add the shard to your `shard.yml`:

```yaml
dependencies:
  marcel:
    github: OrelSokolov/marcel.cr
```

2. Run `shards install`.

## Usage

```crystal
require "marcel"

Marcel::MimeType.for(Path["file.gif"])                       # => "image/gif"
Marcel::MimeType.for(IO::Memory.new(File.read("file.docx"))) # => "application/vnd..."
Marcel::MimeType.for(name: "file.xml")                       # => "application/xml"
Marcel::MimeType.for(extension: "pdf")                       # => "application/pdf"
Marcel::MimeType.for(Path["book.mov"], name: "book.m4v",
                     declared_type: "video/mp4")             # priority: magic → name → type
```

`MimeType.for` accepts a `Path` (a file), an `IO` (content), a `String`
(content) or `nil`, plus optional hints: `name`, `extension`, `declared_type`.
A later candidate is used only if it is more specific than the type already
found. If no type can be determined, `application/octet-stream` is returned.

Low-level API:

```crystal
Marcel::Magic.by_path("image.png")    # => Marcel::Magic?
Marcel::Magic.by_extension("png")     # => Marcel::Magic?
Marcel::Magic.by_type("image/png")    # => Marcel::Magic?
Marcel::Magic.by_magic(io)            # slow: content analysis
Marcel::Magic.all_by_magic(io)        # all matching types

magic = Marcel::Magic.new("text/html")
magic.text?   # => true
magic.image?  # => false
magic.extensions
magic.child_of?("text/plain")

# Extending the registry (mutations are global, as in the Ruby gem):
Marcel::Magic.add("application/x-my-thing", extensions: "mtg",
                  parents: "application/json")
Marcel::Magic.remove("application/x-my-thing")
Marcel::Magic.canonicalize("application/x-my-thing", "text/x-my-thing")
Marcel::MimeType.extend("application/x-my-thing", extensions: %w(mtg))
```

## Differences from the Ruby version

- `Path` instead of `Pathname`; a `String` argument is treated as content, not a path.
- Magic rule regexes run on PCRE2 (always in UTF mode) instead of Onigmo with
  the `/n` flag; the byte semantics are reproduced (see `src/marcel/magic/xml.cr`).
- Non-UTF-8 XML document encodings are transcoded via iconv.

## Development

```
crystal spec                # port of the gem's test suite (639 examples)
                            # + oracle cross-check (525 examples)
```

The cross-check compares the port against reference answers from the Ruby gem
(`spec/oracle_expected.yml`). Regenerating the reference requires a system
Ruby:

```
ruby script/generate_oracle_expected.rb
```

`script/generate_tables.rb` regenerates `src/marcel/tables.cr` from the
oracle gem (usually not needed — the tables are already generated).

## License

Same as the original gem — MIT and Apache-2.0. This port includes code from
marcel (Copyright © Tom Ward and contributors) and mimemagic (Copyright © 2011
Daniel Mendler, MIT).
