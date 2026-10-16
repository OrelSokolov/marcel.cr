# Code in this file adapted from the marcel ruby gem (1:1 port).
# Originally adapted from the mimemagic gem, released under the MIT License.
# Copyright (c) 2011 Daniel Mendler. Available at https://github.com/mimemagicrb/mimemagic.

require "./tables"

module Marcel
  alias MagicOffset = Int32 | Range(Int32, Int32)
  alias MagicValue = Bytes | Regex | Nil

  # Одно правило сопоставления: смещение (точное или диапазон), значение
  # (байты, regexp или nil) и необязательные дочерние правила (AND).
  struct MagicRule
    getter offset : MagicOffset
    getter value : MagicValue
    getter children : Array(MagicRule)?

    def initialize(@offset : MagicOffset, @value : MagicValue, children : Array(MagicRule) | Nil = nil)
      @children = children
    end
  end

  # Запись в реестре MAGIC: тип + список правил (OR между правилами).
  class MagicEntry
    property type : String
    getter rules : Array(MagicRule)

    def initialize(@type : String, @rules : Array(MagicRule))
    end
  end

  # Mime type detection
  class Magic
    getter type : String
    getter mediatype : String
    getter subtype : String

    # Mime type by type string
    def initialize(type : String)
      @type = type
      parts = type.split("/", 2, remove_empty: true)
      @mediatype = parts[0]? || ""
      @subtype = parts[1]? || ""
    end

    # Add custom mime type. Arguments:
    # * *type*: Mime type
    # * *extensions*: String or list of file extensions
    # * *parents*: String or list of parent mime types
    # * *aliases*: String or list of aliased mime types
    # * *magic*: Mime magic specification
    def self.add(type : String, extensions : String | Array(String) | Nil = nil,
                 parents : String | Array(String) | Nil = nil,
                 aliases : String | Array(String) | Nil = nil,
                 magic : Array(MagicRule) | Nil = nil)
      aliases = array_of(aliases).map(&.downcase) - [type.downcase]
      aliases.each do |aliased|
        if TYPE_EXTS.has_key?(aliased) || TYPE_PARENTS.has_key?(aliased) || MAGIC.any? { |entry| entry.type == aliased }
          raise ArgumentError.new("#{aliased} is a registered type; use canonicalize to alias it to #{type}")
        end
      end

      extensions = array_of(extensions)
      TYPE_EXTS[type] = extensions
      extensions.each { |ext| EXTENSIONS[ext] = type }

      TYPE_ALIASES.delete(type)
      aliases.each { |aliased| TYPE_ALIASES[aliased] = type }

      parents = array_of(parents)
      TYPE_PARENTS[type] = parents unless parents.empty?

      MAGIC.unshift(MagicEntry.new(type, magic)) if magic
    end

    # Renames a canonical type: the *instead_of* type's extensions, magic matchers, parents,
    # and aliases are re-registered under *type*, and the old name becomes an alias of the
    # new. Useful when a historical or de facto type is preferable to the canonical type
    # shipped in the generated tables, without giving up its matchers.
    def self.canonicalize(type : String, instead_of : String)
      raise ArgumentError.new("#{instead_of} is an alias, not canonical") if TYPE_ALIASES[instead_of]?

      # Displace whatever the new canonical type was registered as before.
      remove(type)

      # Re-register the old canonical type's dictionary under the new name.
      EXTENSIONS.each do |ext, existing|
        EXTENSIONS[ext] = type if existing == instead_of
      end

      if extensions = TYPE_EXTS.delete(instead_of)
        TYPE_EXTS[type] = extensions
      end

      TYPE_ALIASES.each do |aliased, canonical|
        TYPE_ALIASES[aliased] = type if canonical == instead_of
      end

      if parents = TYPE_PARENTS.delete(instead_of)
        TYPE_PARENTS[type] = parents
      end

      MAGIC.each { |entry| entry.type = type if entry.type == instead_of }

      # Alias the old canonical type to the new.
      TYPE_ALIASES[instead_of] = type
    end

    # Removes a mime type from the dictionary. You might want to do this if
    # you're seeing impossible conflicts (for instance, application/x-gmc-link).
    # * *type*: The mime type to remove. All associated extensions, magic,
    #   and aliases are removed too.
    def self.remove(type : String)
      EXTENSIONS.reject! { |_, t| t == type }
      MAGIC.reject! { |entry| entry.type == type }
      TYPE_EXTS.delete(type)
      TYPE_PARENTS.delete(type)
      TYPE_ALIASES.reject! { |aliased, canonical| aliased == type || canonical == type }
    end

    # Returns true if type is a text format
    def text? : Bool
      mediatype == "text" || child_of?("text/plain")
    end

    # Mediatype shortcuts
    def image? : Bool
      mediatype == "image"
    end

    def audio? : Bool
      mediatype == "audio"
    end

    def video? : Bool
      mediatype == "video"
    end

    # Returns true if type is child of parent type
    def child_of?(parent : String) : Bool
      self.class.child?(type, parent)
    end

    # Get string list of file extensions
    def extensions : Array(String)
      TYPE_EXTS[type]? || [] of String
    end

    # Resolve an aliased type to its canonical type; canonical types return themselves
    def canonical : Magic
      if canonical_type = TYPE_ALIASES[type]?
        Magic.new(canonical_type)
      else
        self
      end
    end

    # Get mime comment
    def comment : Nil
      nil # deprecated
    end

    # Lookup canonical mime type by mime type string, resolving aliases
    def self.by_type(type : String?) : Magic?
      Magic.new(canonical(type).not_nil!) if type
    end

    # Lookup mime type by file extension
    def self.by_extension(ext : String) : Magic?
      return nil unless ext.valid_encoding?

      ext = ext.downcase
      mime = EXTENSIONS[ext.starts_with?('.') ? ext[1..] : ext]?
      mime ? Magic.new(mime) : nil
    end

    # Lookup mime type by filename
    def self.by_path(path : String) : Magic?
      # Ruby: by_extension(File.extname(path)) rescue ArgumentError/EncodingError.
      # Кодировку проверяет by_extension (extname может быть валидным даже у
      # пути с невалидными байтами в базовом имени); Ruby бросает ArgumentError
      # на NUL — Crystal прощает, проверяем сами.
      return nil if path.includes?('\0')

      by_extension(File.extname(path))
    end

    # Lookup mime type by magic content analysis.
    # This is a slow operation.
    def self.by_magic(io : IO | Path | String) : Magic?
      mime = magic_match(io, all: false)
      mime ? Magic.new(mime.as(MagicEntry).type) : nil
    end

    # Lookup all mime types by magic content analysis.
    # This is a slower operation.
    def self.all_by_magic(io : IO | Path | String) : Array(Magic)
      result = magic_match(io, all: true).as(Array(MagicEntry))
      result.map { |entry| Magic.new(entry.type) }
    end

    # Return type as string
    def to_s : String
      type
    end

    # Allow comparison with string
    def eql?(other) : Bool
      type == other.to_s
    end

    def ==(other) : Bool
      eql?(other)
    end

    def hash(hasher)
      type.hash(hasher)
      hasher
    end

    def self.child?(child : String, parent : String) : Bool
      parent = canonical(parent).not_nil!
      pending = [child]
      visited = Set(String).new

      until pending.empty?
        type = canonical(pending.pop).not_nil!
        return true if type == parent
        next if visited.includes?(type)

        visited << type
        pending.concat(TYPE_PARENTS[type]? || [] of String)
      end

      false
    end

    # Resolve an aliased type string to its canonical type string
    def self.canonical(type : String?) : String?
      if type
        type = type.downcase if type =~ /[A-Z]/
        TYPE_ALIASES[type]? || type
      end
    end

    def self.magic_match(io : IO | Path | String, all : Bool)
      case io
      when Path then return File.open(io) { |file| magic_match(file, all) }
      when String then io = IO::Memory.new(io)
      end

      io.rewind
      body_failed = true
      begin
        result = all ? MAGIC.select { |entry| magic_match_io(io, entry.rules) }
                      : MAGIC.find { |entry| magic_match_io(io, entry.rules) }
        body_failed = false
        result
      ensure
        begin
          io.rewind
        rescue e : Exception
          raise e unless body_failed
        end
      end
    end

    def self.magic_match_io(io : IO, matches : Array(MagicRule)) : Bool
      matches.any? do |rule|
        offset = rule.offset
        value = rule.value
        children = rule.children

        match = false
        if value
          is_range = offset.is_a?(Range)
          sample_size = value.is_a?(Regex) ? 256 : value.size

          x = if r = offset.as?(Range(Int32, Int32))
            if io_seek(io, r.begin)
              io_read(io, r.end - r.begin + sample_size)
            end
          else
            if io_seek(io, offset.as(Int32))
              io_read(io, sample_size)
            end
          end

          match = case value
          when Regex
            # PCRE2 в Crystal всегда в UTF-режиме: субъект моем через scrub
            # (невалидные байты → U+FFFD), шаблоны ASCII — семантика сохраняется.
            !!x.try { |bytes| value.matches?(String.new(bytes).scrub) }
          else
            if is_range
              !!x.try { |bytes| bytes_includes?(bytes, value) }
            else
              x == value
            end
          end
        end

        io.rewind
        match && (children.nil? || magic_match_io(io, children))
      end
    end

    def self.io_seek(io : IO, offset : Int32) : Bool
      return true if offset == 0

      if offset < 0
        # Аналог Ruby io.respond_to?(:size): только IO, знающий свой размер,
        # поддерживает отрицательные смещения (IO::Memory, File).
        return false unless io.responds_to?(:size)

        offset = (offset.to_i64 + io.size).to_i32
        return false if offset < 0
      end

      begin
        io.seek(offset, IO::Seek::Set)
      rescue IO::Error
        # Some IOs don't support `seek`. e.g. Rack::RewindableInput
        skipped = io_read(io, offset)
        return false unless skipped && skipped.size == offset
      end

      true
    end

    def self.io_read(io : IO, length : Int32) : Bytes?
      return nil if length <= 0

      buffer = Bytes.new(length)
      filled = 0
      while filled < length
        # EOF-проба через peek, где поддерживается, не тратит вызов read
        # (в Ruby IO#read(length) возвращает короткий результат без пробы).
        if filled > 0 && (peeked = io.peek) && peeked.empty?
          break
        end

        read = begin
          io.read(buffer + filled)
        rescue IndexError
          # IO#seek за конец IO::Memory переносит pos за bytesize; последующий
          # read получает отрицательный остаток. Ruby IO#read здесь даёт EOF.
          0
        end
        break if read == 0
        filled += read
      end

      return nil if filled == 0
      buffer[0, filled]
    end

    private def self.array_of(value : String | Array(String) | Nil) : Array(String)
      case value
      when String then [value]
      when Array(String) then value
      else [] of String
      end
    end

    private def self.bytes_includes?(haystack : Bytes, needle : Bytes) : Bool
      return false if needle.size > haystack.size
      (0..haystack.size - needle.size).each do |i|
        return true if haystack[i, needle.size] == needle
      end
      false
    end
  end
end

require "./magic/definitions"
require "./magic/xml"
require "./magic/zip"
