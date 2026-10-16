module Marcel
  class MimeType
    BINARY = "application/octet-stream"
    MAX_DECLARED_TYPE_BYTES = 8 * 1024
    TOKEN = "[!#$%&'*+\\-.^_`|~0-9A-Za-z]+"
    QUOTED_STRING = "\"(?:[\\t\\x20\\x21\\x23-\\x5B\\x5D-\\x7E\\x80-\\xFF]|\\\\[\\t\\x20-\\x7E\\x80-\\xFF])*\""

    def self.canonicalize(type : String, instead_of : String)
      Magic.canonicalize type, instead_of: instead_of
    end

    def self.extend(type : String, extensions : String | Array(String) | Nil = nil,
                    aliases : String | Array(String) | Nil = nil,
                    parents : String | Array(String) | Nil = nil,
                    magic : Array(MagicRule) | Nil = nil)
      type = type.downcase

      if canonical = Marcel::TYPE_ALIASES[type]?
        STDERR.puts "#{type} is an alias; extending its canonical type #{canonical} instead"
        type = canonical
      end

      extensions = array_of(extensions)
      if !extensions.empty? && extensions.sort == array_of(Marcel::TYPE_EXTS[type]?).sort
        STDERR.puts "#{type} already has extensions #{extensions}"
      end
      extensions |= array_of(Marcel::TYPE_EXTS[type]?)

      aliases = array_of(aliases)
      existing_aliases = Marcel::TYPE_ALIASES.select { |_, existing| existing == type }.keys
      if !aliases.empty? && aliases.sort == existing_aliases.sort
        STDERR.puts "#{type} already has aliases #{aliases}"
      end
      aliases |= existing_aliases

      parents = array_of(parents)
      if !parents.empty? && parents.sort == array_of(Marcel::TYPE_PARENTS[type]?).sort
        STDERR.puts "#{type} already has parents #{parents}"
      end
      parents |= array_of(Marcel::TYPE_PARENTS[type]?)

      # No duplicate-magic warning: matcher order determines precedence, so re-registering
      # an existing matcher legitimately promotes it ahead of the generated tables.
      Magic.add(type, extensions: extensions, magic: magic, aliases: aliases, parents: parents)
    end

    # Returns the most appropriate content type for the given file.
    #
    # The first argument should be a +Path+ or an +IO+ (+String+ рассматривается
    # как содержимое файла, как в Ruby-версии). If it is a +Path+, the specified
    # file will be opened first.
    #
    # Optional parameters:
    # * *name*: file name, if known
    # * *extension*: file extension, if known
    # * *declared_type*: MIME type, if known
    #
    # The most appropriate type is determined by the following:
    # * type declared by binary magic number data
    # * valid declared MIME type, unless it is application/octet-stream
    # * type inferred from the file name or extension
    #
    # A later candidate is used only if it is more specific than the type already found.
    #
    # The result is a best-effort label, not validation that the file is safe or conforms to
    # the returned type. Treat +name+ and +declared_type+ as hints from their respective sources.
    #
    # If no type can be determined, then +application/octet-stream+ is returned.
    def self.for(path_or_io : IO | Path | String | Nil = nil, *,
                 name : String? = nil, extension : String? = nil,
                 declared_type : String? = nil) : String
      filename_type = for_name(name) || for_extension(extension)
      most_specific_type(for_data(path_or_io), for_declared_type(declared_type), filename_type, BINARY)
    end

    def self.for_data(path_or_io : IO | Path | String | Nil) : String?
      return unless path_or_io

      case path_or_io
      when Path then File.open(path_or_io) { |file| detect_by_magic(file) }
      when String then detect_by_magic(IO::Memory.new(path_or_io))
      else detect_by_magic(path_or_io)
      end
    end

    def self.for_name(name : String?) : String?
      if name
        if magic = Marcel::Magic.by_path(name)
          magic.canonical.type.downcase
        end
      end
    end

    def self.for_extension(extension : String?) : String?
      if extension
        if magic = Marcel::Magic.by_extension(extension)
          magic.canonical.type.downcase
        end
      end
    end

    def self.for_declared_type(declared_type : String?) : String?
      type = Marcel::Magic.canonical(parse_media_type(declared_type))

      # application/octet-stream is treated as an undeclared/missing type,
      # allowing the type to be inferred from the filename. If there's no
      # filename extension, then the type falls back to binary anyway.
      return type if type && type != BINARY
    end

    def self.parse_media_type(content_type : String?) : String?
      return unless content_type
      return if content_type.bytesize > MAX_DECLARED_TYPE_BYTES

      # Побайтовый разбор, эквивалентный Ruby-регэкспу MEDIA_TYPE (/n):
      # TOKEN "/" TOKEN ( ";" SP* TOKEN "=" (TOKEN | QUOTED_STRING) )* [ ";" SP* ] EOF,
      # где SP = [ \t]. Ведущие/замыкающие [ \t\r\n] срезаются.
      bytes = content_type.to_slice
      size = bytes.size

      start = 0
      while start < size && HTTP_WS.includes?(bytes[start])
        start += 1
      end
      stop = size - 1
      while stop >= start && HTTP_WS.includes?(bytes[stop])
        stop -= 1
      end
      return nil if stop < start

      pos = start
      type_end = scan_token(bytes, pos, stop)
      return nil unless type_end && type_end < stop && bytes[type_end] == 0x2F # '/'
      return nil unless type_end > pos # непустой основной тип
      media_type_end = scan_token(bytes, type_end + 1, stop)
      return nil unless media_type_end && media_type_end > type_end + 1 # непустой подтип
      pos = media_type_end

      loop do
        while pos <= stop && (bytes[pos] == 0x20 || bytes[pos] == 0x09)
          pos += 1
        end
        # необязательная завершающая ";" [ \t]*
        break if pos > stop
        return nil unless bytes[pos] == 0x3B # ';'
        pos += 1
        while pos <= stop && (bytes[pos] == 0x20 || bytes[pos] == 0x09)
          pos += 1
        end
        break if pos > stop # завершающая ";"

        # параметр: TOKEN "=" (TOKEN | QUOTED_STRING)
        param_end = scan_token(bytes, pos, stop)
        return nil unless param_end && param_end > pos
        pos = param_end
        while pos <= stop && (bytes[pos] == 0x20 || bytes[pos] == 0x09)
          pos += 1
        end
        return nil unless pos <= stop && bytes[pos] == 0x3D # '='
        pos += 1
        while pos <= stop && (bytes[pos] == 0x20 || bytes[pos] == 0x09)
          pos += 1
        end
        return nil unless pos <= stop

        if bytes[pos] == 0x22 # '"'
          pos = scan_quoted_string(bytes, pos, stop)
          return nil unless pos
        else
          value_end = scan_token(bytes, pos, stop)
          return nil unless value_end && value_end > pos
          pos = value_end
        end
      end

      String.new(bytes[start, media_type_end - start]).downcase
    end

    private def self.scan_token(bytes : Bytes, pos : Int32, stop : Int32) : Int32?
      i = pos
      while i <= stop && TOKEN_BYTES.includes?(bytes[i])
        i += 1
      end
      i > pos ? i : nil
    end

    private def self.scan_quoted_string(bytes : Bytes, pos : Int32, stop : Int32) : Int32?
      # QUOTED_STRING: '"' ( RAW | '\' ESC )* '"' с побайтовой семантикой Ruby (/n):
      # RAW — любой байт, кроме 0x00-0x08, 0x0A-0x1F, '"', '\', 0x7F;
      # ESC — [\t\x20-\x7E\x80-\xFF].
      i = pos + 1
      while i <= stop
        case bytes[i]
        when 0x22 then return i + 1
        when 0x5C # backslash
          return nil if i + 1 > stop || bytes[i + 1] < 0x09 || bytes[i + 1] == 0x7F
          i += 2
        else
          return nil if bytes[i] < 0x20 && bytes[i] != 0x09
          i += 1
        end
      end
      nil
    end

    HTTP_WS = Bytes[0x20, 0x09, 0x0D, 0x0A]
    TOKEN_BYTES = Set.new(("!#$%&'*+-.^_`|~0123456789" \
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ").each_byte.to_a)

    # For some document types (notably Microsoft Office) we recognise the main content
    # type with magic, but not the specific subclass. In this situation, if we can get a more
    # specific class using either the name or declared_type, we should use that in preference
    def self.most_specific_type(*candidates : String | Nil) : String
      types = candidates.to_a.compact.uniq
      type = types.first
      types.skip(1).each do |candidate|
        type = Marcel::Magic.child?(candidate, type) ? candidate : type
      end
      type
    end

    def self.detect_by_magic(io : IO) : String?
      if magic = Marcel::Magic.by_magic(io)
        type = magic.canonical.type.downcase
        Marcel::Magic::Xml.refine(io, Marcel::Magic::Zip.refine(io, type))
      end
    end

    private def self.array_of(value : String | Array(String) | Nil) : Array(String)
      case value
      when String then [value]
      when Array(String) then value
      else [] of String
      end
    end
  end
end

require "./mime_type/definitions"
