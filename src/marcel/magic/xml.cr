# Перенос lib/marcel/magic/xml.rb гема (1:1).
#
# Проблемы Ruby→Crystal:
# * PCRE2 в Crystal всегда компилируется с UTF|UCP, поэтому Ruby-семантика
#   /n («любой байт») выражается диапазоном до U+10FFFF, а регэкспы,
#   работающие по потенциально невалидному UTF-8, компилируются с
#   MATCH_INVALID_UTF (невалидный хвост не мешает совпадению до него
#   и не бросает исключение, как в Ruby /n);
# * \G-якоря совмещены с match_at_byte_index (эквивалент Ruby
#   Regexp#match(str, pos) с \G);
# * Unicode-грамматики имён (NCNAME/XML_NAME) и запреты литеральных символов
#   (FORBIDDEN_CHARS) реализованы вручную по кодовым точкам;
# * транскодирование кодировок — через iconv (Crystal::Iconv), режим
#   replace (invalid/undef → U+FFFD) реализован собственным циклом.

require "crystal/iconv"

module Marcel
  class Magic
    # Procedural refinement of XML documents by their root element.
    #
    # Many XML vocabularies — feeds, KML, property lists, XSLT, Office 2003 XML — share the
    # same leading bytes, and a prolog of arbitrary length (declaration, comments, DOCTYPE)
    # can precede the element that tells them apart. Apache Tika identifies them by the root
    # element's namespace and local name instead, and those rules are generated into
    # ROOT_XML. This module scans a bounded prefix past the prolog to the root start-tag,
    # resolves the root's namespace from its own xmlns declarations, and looks the pair up
    # to refine a generic application/xml match.
    module Xml
      REFINABLE_TYPE = "application/xml"

      # Tika examines at most this much of a document for its root element.
      MAX_SCAN = 64 * 1024

      UTF8_BOM = "\xEF\xBB\xBF"
      UTF16LE_BOM = "\xFF\xFE"
      UTF16BE_BOM = "\xFE\xFF"

      # Scanner pattern for names: XML Name restricted to ASCII plus any
      # non-ASCII character (в UTF-режиме PCRE2 — до U+10FFFF включительно,
      # аналог любого не-ASCII байта в Ruby /n). It only locates tokens; every
      # captured name is then validated against the real Unicode name grammar
      # (valid_name? below) after decoding.
      NAME = "[A-Za-z_:\\x80-\\x{10FFFF}][A-Za-z0-9._:\\-\\x80-\\x{10FFFF}]*"
      SPACE = "[ \\t\\r\\n]"
      ENCODING_NAME = "[A-Za-z][A-Za-z0-9._\\-]*"

      # Сканер работает по сырым (возможно, невалидным) UTF-8 байтам, как
      # Ruby-регэкспы с флагом /n: MATCH_INVALID_UTF запрещает совпадения
      # сквозь невалидные последовательности, но не мешает совпадениям до них
      # и не бросает ArgumentError.
      SCAN = Regex::Options::MATCH_INVALID_UTF

      WHITESPACE = Regex.new("\\G#{SPACE}*", SCAN)
      START_TAG = Regex.new("\\G<(#{NAME})", SCAN)
      ATTRIBUTE = Regex.new("\\G#{SPACE}+(#{NAME})#{SPACE}*=#{SPACE}*(?:\"([^\"<]*)\"|'([^'<]*)')", SCAN)
      START_TAG_END = Regex.new("\\G#{SPACE}*\\/?>", SCAN)
      PROCESSING_INSTRUCTION = Regex.new("\\G<\\?(#{NAME})", SCAN)
      RESERVED_TARGET = Regex.new("\\A[Xx][Mm][Ll]\\z", SCAN)

      # The complete declaration grammar: a SAX-supported version, then optionally encoding,
      # then optionally standalone, in that order, with nothing else before ?>. Matched in
      # full so that trailing or duplicated tokens cannot hide behind the PI skipper.
      # (группы: 1,2 — version; 3,4 — encoding)
      XML_DECLARATION = Regex.new(
        "\\A<\\?xml#{SPACE}+version#{SPACE}*=#{SPACE}*(?:\"(1\\.[01])\"|'(1\\.[01])')" +
        "(?:#{SPACE}+encoding#{SPACE}*=#{SPACE}*(?:\"(#{ENCODING_NAME})\"|'(#{ENCODING_NAME})'))?" +
        "(?:#{SPACE}+standalone#{SPACE}*=#{SPACE}*(?:\"(?:yes|no)\"|'(?:yes|no)'))?" +
        "#{SPACE}*\\?>", SCAN)

      # Entity and character references; anything else after & in an attribute value is a
      # well-formedness error. (группы: 1 — имя, 2 — decimal, 3 — hex)
      REFERENCE = Regex.new("&(?:(#{NAME})|\\#([0-9]+)|\\#x([0-9A-Fa-f]+));", SCAN)

      PREDEFINED_ENTITIES = %w(amp lt gt apos quot)

      XML_NAMESPACE = "http://www.w3.org/XML/1998/namespace"
      XMLNS_NAMESPACE = "http://www.w3.org/2000/xmlns/"

      PROCESSING_INSTRUCTION_OPEN = "<?"
      PROCESSING_INSTRUCTION_CLOSE = "?>"
      COMMENT_OPEN = "<!--"
      COMMENT_CLOSE = "-->"
      DOUBLE_HYPHEN = "--"
      DOCTYPE_OPEN = "<!DOCTYPE"
      SPACE_BYTES = [0x20, 0x09, 0x0D, 0x0A]
      DOCTYPE_DELIMITERS = Bytes[0x22, 0x27, 0x5B, 0x5D, 0x3C, 0x3E]

      REPLACEMENT_CHARACTER = "\u{FFFD}"

      # Ruby резолвит их в процессные умолчания, а не в charset.
      PSEUDO_ENCODING_NAMES = %w(locale external filesystem)

      # Не-ASCII-совместимые и «dummy» кодировки Ruby (UTF-16/32, UCS, UTF-7,
      # ISO-2022-*, HZ) и псевдонимы бинарной — iconv их знает, но скан байтов
      # по ним невозможен; find_encoding их отклоняет, как Encoding#find + проверки.
      REJECTED_ENCODING = /utf-?7|utf-?16|utf-?32|ucs-?2|ucs-?4|iso-2022|hz|ansi_x3\.110|binary|ascii-8bit/i

      # Returns the type ROOT_XML assigns to the IO's root element if +base_type+ is the
      # generic XML type and the root element can be read, or +base_type+ unchanged.
      # Partial reads, roots past MAX_SCAN, malformed or mis-encoded prologs, namespace
      # errors and unknown roots refine nothing: the base type stands.
      def self.refine(io : IO | String, base_type : String) : String
        return base_type unless base_type == REFINABLE_TYPE

        io = IO::Memory.new(io.to_s) unless io.is_a?(IO)

        root = nil
        begin
          if decoded = decode(read_prefix(io))
            root = root_element(decoded[0], decoded[1], decoded[2])
          end
        rescue e : Exception
          nil
        ensure
          begin
            io.rewind
          rescue e : Exception
            nil
          end
        end

        if root && (type = ROOT_XML[root]?)
          Magic.canonical(type).not_nil!
        else
          base_type
        end
      end

      def self.read_prefix(io : IO) : String
        io.rewind
        prefix = IO::Memory.new
        while prefix.bytesize < MAX_SCAN
          remaining = MAX_SCAN - prefix.bytesize
          buffer = Bytes.new(remaining)
          filled = 0
          while filled < remaining
            read = io.read(buffer + filled)
            break if read == 0
            filled += read
          end
          break if filled == 0
          prefix.write(buffer[0, filled])
        end
        prefix.to_s.byte_slice(0, MAX_SCAN)
      end

        # Returns {текст для сканирования, режим (:utf8/:replaced), версия XML}, или nil,
        # когда префикс не декодируется. Сканирование всегда читает UTF-8 байты: magic-гейт
        # гарантирует BOM на UTF-16 входе, который строго транскодируется заранее;
        # документы уже в UTF-8 сканируются как есть; любая другая объявленная кодировка
        # транскодируется с заменой (invalid/undef → U+FFFD), так как её многобайтовые
        # символы могут нести ASCII-подобные хвостовые байты (Shift_JIS ソ кончается на
        # ASCII-бэкслеш), которые саботировали бы побайтовое сканирование.
        def self.decode(prefix : String) : Tuple(String, Symbol, String)?
          if prefix.bytesize >= 2 && prefix.byte_slice(0, 2) == UTF16LE_BOM
            data = transcode(prefix.unsafe_byte_slice(2), "UTF-16LE")
            if declaration = xml_declaration(data)
              {data, :utf8, declaration[0]}
            end
          elsif prefix.bytesize >= 2 && prefix.byte_slice(0, 2) == UTF16BE_BOM
            data = transcode(prefix.unsafe_byte_slice(2), "UTF-16BE")
            if declaration = xml_declaration(data)
              {data, :utf8, declaration[0]}
            end
          else
            data = prefix.bytesize >= 3 && prefix.byte_slice(0, 3) == UTF8_BOM ? prefix.byte_slice(3) : prefix
            if declaration = xml_declaration(data)
              version, name = declaration
              encoding = name ? find_encoding(name) : "UTF-8"
              if encoding == "UTF-8"
                {data, :utf8, version}
              elsif encoding
                {reencode(data.to_slice, encoding), :replaced, version}
              end
            end
          end
        end

        # A code unit or surrogate pair split by the scan limit is the one sequence that
        # may legitimately be incomplete: it is dropped, since it lies beyond the scan.
        # Any other invalid sequence raises and refines nothing.
        def self.transcode(bytes : Bytes, encoding : String) : String
          bytes = bytes[0, bytes.size & ~1]
          begin
            String.new(bytes, encoding)
          rescue ArgumentError
            String.new(bytes[0, bytes.size - 2], encoding)
          end
        end

        # Replace-transcodes a legacy-encoded prefix to UTF-8 (аналог Ruby
        # encode(invalid: :replace, undef: :replace)): каждая невалидная или
        # непредставимая последовательность становится U+FFFD.
        def self.reencode(bytes : Bytes, encoding : String) : String
          out = IO::Memory.new
          Crystal::Iconv.new(encoding, "UTF-8") do |iconv|
            inbuf = bytes.to_unsafe
            inleft = LibC::SizeT.new(bytes.size)
            buffer = uninitialized UInt8[1024]

            while inleft > 0
              outbuf = buffer.to_unsafe
              outleft = LibC::SizeT.new(buffer.size)
              err = iconv.convert(pointerof(inbuf), pointerof(inleft), pointerof(outbuf), pointerof(outleft))
              out.write(buffer.to_slice[0, buffer.size - outleft])
              next if err != Crystal::Iconv::ERROR

              break if inleft == 0
              out << REPLACEMENT_CHARACTER
              inbuf += 1
              inleft -= 1
            end

            outbuf = buffer.to_unsafe
            outleft = LibC::SizeT.new(buffer.size)
            iconv.convert(Pointer(UInt8*).null, Pointer(LibC::SizeT).null, pointerof(outbuf), pointerof(outleft))
            out.write(buffer.to_slice[0, buffer.size - outleft])
          end
          out.to_s
        end

        # Returns {version, declared encoding name or nil} when the document either has no
        # XML declaration (version defaults to 1.0) or opens with one that is well-formed
        # in full, and nil when it opens with a malformed declaration or a processing
        # instruction that misuses the xml target.
        def self.xml_declaration(data : String) : Tuple(String, String?)?
          return {"1.0", nil} unless data.starts_with?(PROCESSING_INSTRUCTION_OPEN)
          target = PROCESSING_INSTRUCTION.match_at_byte_index(data, 0)
          return nil unless target
          target_name = target[1]?
          return {"1.0", nil} unless target_name && RESERVED_TARGET.matches?(target_name)

          if declaration = XML_DECLARATION.match(data)
            version = declaration[1]? || declaration[2]? || "1.0"
            {version, declaration[3]? || declaration[4]?}
          end
        end

        def self.find_encoding(name : String) : String?
          return nil if PSEUDO_ENCODING_NAMES.includes?(name.downcase)
          return nil if name =~ REJECTED_ENCODING

          begin
            Crystal::Iconv.new(name, "UTF-8") { |iconv| iconv }
            name
          rescue ArgumentError
            nil
          end
        end

        # Skips the prolog — whitespace, processing instructions (including the XML
        # declaration), comments and the document type declaration — and returns the
        # root element's {namespace, local name}, or nil if no root start-tag is found.
        def self.root_element(data : String, mode : Symbol, version : String) : Tuple(String?, String?)?
          pos = 0
          doctype_seen = false
          while pos
            whitespace = WHITESPACE.match_at_byte_index(data, pos).not_nil!
            pos = whitespace.byte_end(0)

            if byteslice?(data, pos, 2) == PROCESSING_INSTRUCTION_OPEN
              pos = skip_processing_instruction(data, pos)
            elsif byteslice?(data, pos, 4) == COMMENT_OPEN
              pos = skip_comment(data, pos)
            elsif byteslice?(data, pos, 9) == DOCTYPE_OPEN
              doctype_seen = true
              pos = skip_doctype(data, pos + 9)
            else
              return parse_start_tag(data, pos, mode, version, doctype_seen)
            end
          end
          nil
        end

        # The XML declaration is the one processing instruction allowed the xml target,
        # and only as the very first bytes of the document (checked by xml_declaration).
        # A PI's data, when present, must be separated from its target by whitespace.
        def self.skip_processing_instruction(data : String, pos : Int32) : Int32?
          target = PROCESSING_INSTRUCTION.match_at_byte_index(data, pos)
          return nil unless target
          name = target[1]?
          return nil unless name
          return nil if pos != 0 && RESERVED_TARGET.matches?(name)
          unless (pos == 0 && RESERVED_TARGET.matches?(name)) || valid_name?(name, xml_name: true)
            return nil
          end

          after = target.byte_end(0)
          unless byteslice?(data, after, 2) == PROCESSING_INSTRUCTION_CLOSE ||
                 (byte = byte_at?(data, after)) && SPACE_BYTES.includes?(byte)
            return nil
          end

          skip_past(data, PROCESSING_INSTRUCTION_CLOSE, after)
        end

        # A comment ends at its first "--", which must be the one closing it.
        def self.skip_comment(data : String, pos : Int32) : Int32?
          return nil if pos + 4 > data.bytesize
          close = data.byte_index(DOUBLE_HYPHEN, pos + 4)
          if close && data.byte_slice(close, {3, data.bytesize - close}.min) == COMMENT_CLOSE
            close + 3
          end
        end

        def self.skip_past(data : String, terminator : String, pos : Int32) : Int32?
          close = data.byte_index(terminator, pos)
          close + terminator.bytesize if close
        end

        # Advances past a document type declaration, honouring quoted literals and the
        # bracketed internal subset so that markup declarations like
        # <!ENTITY x "<foo>"> and comments within the subset cannot end the scan early.
        def self.skip_doctype(data : String, pos : Int32) : Int32?
          depth = 0
          while pos = next_delimiter(data, pos)
            case data.byte_at(pos)
            when 0x22, 0x27 # " '
              pos = skip_past(data, data.byte_slice(pos, 1), pos + 1)
              return nil unless pos
            when 0x5B # [
              depth += 1
              pos += 1
            when 0x5D # ]
              depth -= 1
              pos += 1
            when 0x3C # <
              if byteslice?(data, pos, 4) == COMMENT_OPEN
                pos = skip_comment(data, pos)
                return nil unless pos
              elsif byteslice?(data, pos, 2) == PROCESSING_INSTRUCTION_OPEN
                pos = skip_processing_instruction(data, pos)
                return nil unless pos
              else
                pos += 1
              end
            else # >
              return pos + 1 if depth <= 0
              pos += 1
            end
          end
          nil
        end

        # Reads the root start-tag's qualified name and attributes. Attribute values are
        # parsed as quoted literals so a > within one cannot truncate the tag; the tag must
        # close within the scanned prefix, and everything consumed up to that point must be
        # valid in the document's encoding and free of forbidden characters.
        def self.parse_start_tag(data : String, pos : Int32, mode : Symbol, version : String, doctype_seen : Bool) : Tuple(String?, String?)?
          tag = START_TAG.match_at_byte_index(data, pos)
          return nil unless tag
          qualified_name = tag[1]?

          pos = tag.byte_end(0)

          attributes = {} of String => String
          while attribute = ATTRIBUTE.match_at_byte_index(data, pos)
            # Duplicate attributes are a well-formedness error (Unique Att Spec).
            return nil if attributes.has_key?(attribute[1])

            attributes[attribute[1]] = attribute[2]? || attribute[3]? || ""
            pos = attribute.byte_end(0)
          end
          tag_end = START_TAG_END.match_at_byte_index(data, pos)
          return nil unless tag_end
          return nil unless valid_text?(data.byte_slice(0, tag_end.byte_end(0)), mode, version)

          bindings = namespace_bindings(attributes, version)
          return nil unless bindings
          return nil unless valid_attributes?(attributes, bindings, version, doctype_seen)

          resolve_name(qualified_name || "", bindings)
        end

        # The consumed prefix must be free of the characters its XML version forbids as
        # literals, wherever they fall — comment, PI, DOCTYPE or attribute — since a SAX
        # parser rejects them before the root. Raw and strictly transcoded input must be
        # valid UTF-8, in which a genuine U+FFFD literal is legal XML; replace-transcoded
        # input must carry no U+FFFD, each one marking a sequence invalid in the declared
        # encoding.
        def self.valid_text?(consumed : String, mode : Symbol, version : String) : Bool
          sound = mode == :replaced ? !consumed.includes?(REPLACEMENT_CHARACTER) : consumed.valid_encoding?
          sound && !contains_forbidden_char?(consumed, version)
        end

        # Names must satisfy the Unicode name grammar once decoded — NCName unless the
        # laxer XML Name (с двоеточием) is requested — with the byte-level scanner
        # accepting a superset purely to locate them.
        def self.valid_name?(name : String, xml_name : Bool = false) : Bool
          return false unless name.valid_encoding?
          return false if name.empty?

          first = true
          name.each_char do |char|
            cp = char.ord
            if first
              return false unless name_start_char?(cp) || (xml_name && cp == ':'.ord)
              first = false
            else
              return false unless name_start_char?(cp) || name_char?(cp) || (xml_name && cp == ':'.ord)
            end
          end
          true
        end

        # A character reference must denote a character the XML version admits: never a
        # surrogate, a noncharacter, or a code point beyond U+10FFFF; XML 1.0 admits only
        # tab, newline, carriage return and #x20 up, while XML 1.1 admits everything from
        # #x1 — including as references the control characters it forbids as literals.
        def self.valid_character_scalar?(value : Int, version : String) : Bool
          return false if value > 0x10FFFF || (0xD800..0xDFFF).includes?(value) ||
                          value == 0xFFFE || value == 0xFFFF

          if version == "1.1"
            value >= 0x1
          else
            value == 0x9 || value == 0xA || value == 0xD || value >= 0x20
          end
        end

        # A character reference admits unlimited leading zeros, so the scalar's magnitude
        # is bounded lexically — at most seven significant decimal digits or six hex
        # cover every code point through U+10FFFF — before conversion, never by
        # converting an unbounded digit run. All zeros denote #x0, rejected as a scalar.
        def self.valid_character_reference?(digits : String, base : Int32, version : String) : Bool
          digits = digits.sub(/\A0+/, "")
          return false unless digits.size <= (base == 16 ? 6 : 7)
          valid_character_scalar?(digits.to_i?(base) || 0, version)
        end

        # Every & in an attribute value must begin a well-formed reference: a character
        # reference to an admissible character, a predefined entity, or — only when a DTD
        # that could declare it was seen — any well-named entity. Never resolved.
        def self.valid_references?(value : String, version : String, doctype_seen : Bool) : Bool
          # Аналог Ruby value.gsub(REFERENCE, ""): каждый корректный reference
          # удаляется, затем в остатке не должно остаться «&». gsub-блок Crystal
          # не даёт доступа к группам, поэтому явный цикл по совпадениям.
          rest = String::Builder.new
          pos = 0
          while match = REFERENCE.match_at_byte_index(value, pos)
            if digits = match[2]?
              return false unless valid_character_reference?(digits, 10, version)
            elsif digits = match[3]?
              return false unless valid_character_reference?(digits, 16, version)
            else
              name = match[1]?.to_s
              unless valid_name?(name, xml_name: true) &&
                     (doctype_seen || PREDEFINED_ENTITIES.includes?(name))
                return false
              end
            end
            rest.write(value.to_slice[pos, match.byte_begin(0) - pos])
            pos = match.byte_end(0)
          end
          rest << value.byte_slice(pos)
          !rest.to_s.includes?("&")
        end

        # Splits a QName into {prefix or nil, local name}; more than one colon or an empty
        # part is a namespace error, returned as nil.
        def self.split_qualified_name(name : String) : Tuple(String?, String?)?
          if name.includes?(":")
            prefix, _, local_name = name.partition(":")
            if prefix.empty? || local_name.empty? || local_name.includes?(":")
              nil
            else
              {prefix, local_name}
            end
          else
            {nil, name}
          end
        end

        # The tag's namespace declarations as {prefix or nil => namespace or nil}, with
        # the xml prefix implicitly bound. The xml and xmlns names and namespaces are
        # reserved. A prefix bound to an empty namespace is an undeclaration, permitted by
        # Namespaces 1.1 (except for xml) and an error under 1.0; violations are namespace
        # errors, returned as nil.
        def self.namespace_bindings(attributes : Hash(String, String), version : String) : Hash(String?, String?)?
          bindings = {nil => nil, "xml" => XML_NAMESPACE} of String? => String?
          attributes.each do |name, value|
            if name == "xmlns"
              return nil if value == XML_NAMESPACE || value == XMLNS_NAMESPACE
              bindings[nil] = value.empty? ? nil : value
            elsif name.starts_with?("xmlns:")
              prefix = name.byte_slice(6)
              return nil if prefix.empty? || prefix.includes?(":") || prefix == "xmlns"

              if value.empty?
                return nil unless version == "1.1" && prefix != "xml"

                bindings.delete(prefix)
              else
                return nil if (prefix == "xml") != (value == XML_NAMESPACE)
                return nil if value == XMLNS_NAMESPACE

                bindings[prefix] = value
              end
            end
          end
          bindings
        end

        # Ordinary attributes resolved by expanded name, as a namespace-aware parser sees
        # them: names must be valid NCNames, prefixes bound, {namespace, local name} pairs
        # unique (the default namespace does not apply to attributes), and values free of
        # malformed references.
        def self.valid_attributes?(attributes : Hash(String, String), bindings : Hash(String?, String?),
                                    version : String, doctype_seen : Bool) : Bool
          expanded = {} of Tuple(String?, String) => Bool
          attributes.each do |name, value|
            return false unless valid_references?(value, version, doctype_seen)

            if name == "xmlns"
              next
            elsif name.starts_with?("xmlns:")
              return false unless valid_name?(name.byte_slice(6))
              next
            end

            split = split_qualified_name(name)
            return false unless split

            prefix, local_name = split
            return false unless valid_name?(local_name)
            return false if prefix && !(valid_name?(prefix) && bindings.has_key?(prefix))

            key = {prefix ? bindings[prefix] : nil, local_name}
            return false if expanded.has_key?(key)

            expanded[key] = true
          end
          true
        end

        # Resolves the root element's name against the tag's own bindings: the default
        # namespace for an unprefixed name, the prefix's binding otherwise. An unbound
        # prefix or invalid name is a namespace error.
        def self.resolve_name(qualified_name : String, bindings : Hash(String?, String?)) : Tuple(String?, String?)?
          split = split_qualified_name(qualified_name)
          return nil unless split

          prefix, local_name = split
          return nil unless valid_name?(local_name)
          return nil if prefix == "xmlns"
          return nil if prefix && !(valid_name?(prefix) && bindings.has_key?(prefix))

          {prefix ? bindings[prefix] : bindings[nil], local_name}
        end

        # NameStartChar под XML 1.0 (5-е изд.), Unicode-грамматика имён.
        def self.name_start_char?(cp : Int32) : Bool
          (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A) || cp == 0x5F ||
            (cp >= 0xC0 && cp <= 0xD6) || (cp >= 0xD8 && cp <= 0xF6) || (cp >= 0xF8 && cp <= 0x2FF) ||
            (cp >= 0x370 && cp <= 0x37D) || (cp >= 0x37F && cp <= 0x1FFF) ||
            (cp >= 0x200C && cp <= 0x200D) || (cp >= 0x2070 && cp <= 0x218F) ||
            (cp >= 0x2C00 && cp <= 0x2FEF) || (cp >= 0x3001 && cp <= 0xD7FF) ||
            (cp >= 0xF900 && cp <= 0xFDCF) || (cp >= 0xFDF0 && cp <= 0xFFFD) ||
            (cp >= 0x10000 && cp <= 0xEFFFF)
        end

        # NameChar: NameStartChar плюс '-' '.' 0-9 U+00B7 U+0300-U+036F U+203F-U+2040.
        def self.name_char?(cp : Int32) : Bool
          cp == 0x2D || cp == 0x2E || (cp >= 0x30 && cp <= 0x39) || cp == 0xB7 ||
            (cp >= 0x300 && cp <= 0x36F) || (cp >= 0x203F && cp <= 0x2040)
        end

        # Символы, запрещённые XML-версией как литералы (аналог FORBIDDEN_CHARS).
        def self.contains_forbidden_char?(text : String, version : String) : Bool
          text.each_char do |char|
            cp = char.ord
            forbidden = cp <= 0x08 || cp == 0x0B || cp == 0x0C || (cp >= 0x0E && cp <= 0x1F) ||
                        cp == 0xFFFE || cp == 0xFFFF
            if !forbidden && version == "1.1"
              forbidden = cp == 0x7F || (cp >= 0x80 && cp <= 0x84) || (cp >= 0x86 && cp <= 0x9F)
            end
            return true if forbidden
          end
          false
        end

        def self.byteslice?(data : String, pos : Int32, size : Int32) : String?
          return nil if pos < 0 || pos + size > data.bytesize
          data.byte_slice(pos, size)
        end

        def self.byte_at?(data : String, pos : Int32) : UInt8?
          data.byte_at(pos) if pos >= 0 && pos < data.bytesize
        end

        def self.next_delimiter(data : String, pos : Int32) : Int32?
          pos = 0 if pos < 0
          while pos < data.bytesize
            return pos if DOCTYPE_DELIMITERS.includes?(data.byte_at(pos))
            pos += 1
          end
          nil
        end
    end
  end
end
