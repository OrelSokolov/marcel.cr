# Перенос lib/marcel/magic/zip.rb гема (1:1).

module Marcel
  class Magic
    # Procedural refinement of ZIP-based container types.
    #
    # The declarative magic tables scan a bounded prefix of the file (matchers are capped at
    # 64KB offsets when the tables are generated), so ZIP containers whose distinguishing
    # members are catalogued later in the archive — such as OOXML documents with
    # [Content_Types].xml stored past the 64KB mark — fall back to their generic container
    # type. This module instead parses the ZIP central directory, a bounded read from the end
    # of the file, to recover the specific document type, including macro-enabled variants,
    # which no prefix bytes can distinguish.
    module Zip
      EOCD_SIGNATURE = "PK\x05\x06".to_slice
      ZIP64_EOCD_SIGNATURE = "PK\x06\x06".to_slice
      ZIP64_EOCD_LOCATOR_SIGNATURE = "PK\x06\x07".to_slice
      CENTRAL_DIRECTORY_SIGNATURE = "PK\x01\x02".to_slice

      EOCD_SIZE = 22
      ZIP64_EOCD_SIZE = 56
      # 4 (сигнатура) + 4 (диск) + 8 (смещение) + 2 (всего дисков, u16 — как
      # в zip.rb: unpack("VQ<V"), 18-байтовая запись).
      ZIP64_EOCD_LOCATOR_SIZE = 18
      MAX_COMMENT_SIZE = 0xFFFF

      # The end-of-central-directory record sits at most a maximal comment from the end of
      # the file, possibly preceded by a Zip64 locator.
      MAX_EOCD_SEARCH = EOCD_SIZE + MAX_COMMENT_SIZE + ZIP64_EOCD_LOCATOR_SIZE

      # A malformed trailer full of EOCD signature bytes could otherwise force a quadratic
      # backward scan; real archives find the record on the first candidate.
      MAX_EOCD_CANDIDATES = 64

      CENTRAL_DIRECTORY_HEADER_SIZE = 46
      MAX_CENTRAL_DIRECTORY_READ = 1 << 20
      MAX_ENTRIES = 8192

      # Container types a central directory listing can make more specific.
      REFINABLE_TYPES = [
        "application/zip",
        "application/x-tika-ooxml",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
      ]

      # Standardised OPC part names identifying each OOXML document family:
      # main part, macro part, and the types each implies.
      DOCUMENT_FAMILIES = [
        {"word/document.xml", "word/vbaProject.bin",
         "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
         "application/vnd.ms-word.document.macroenabled.12"},
        {"xl/workbook.xml", "xl/vbaProject.bin",
         "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
         "application/vnd.ms-excel.sheet.macroenabled.12"},
        {"ppt/presentation.xml", "ppt/vbaProject.bin",
         "application/vnd.openxmlformats-officedocument.presentationml.presentation",
         "application/vnd.ms-powerpoint.presentation.macroenabled.12"},
      ]

      DISCRIMINATING_PARTS = DOCUMENT_FAMILIES.flat_map { |family| [family[0], family[1]] }

      # Returns a more specific type than +base_type+ if the IO's ZIP central directory
      # identifies one, or +base_type+ unchanged. Unseekable IOs, partial reads and
      # malformed archives refine nothing: the base type stands.
      def self.refine(io : IO | String, base_type : String) : String
        return base_type unless REFINABLE_TYPES.includes?(base_type)

        io = IO::Memory.new(io.to_s) unless io.is_a?(IO)

        parts = nil
        begin
          parts = discriminating_parts(io)
        rescue e : Exception
          parts = nil
        ensure
          begin
            io.rewind
          rescue e : Exception
            nil
          end
        end

        parts ? classify(parts.not_nil!, base_type) : base_type
      end

      def self.classify(parts : Array(String), base_type : String) : String
        DOCUMENT_FAMILIES.each do |main_part, macro_part, type, macro_type|
          return parts.includes?(macro_part) ? macro_type : type if parts.includes?(main_part)
        end
        base_type
      end

      # Reads the archive's central directory and returns the OOXML part names it
      # catalogues, or nil if no well-formed central directory is found.
      def self.discriminating_parts(io : IO) : Array(String)?
        # Аналог Ruby io.respond_to?(:seek) && io.respond_to?(:size): без size
        # (Rack-обёртки, pipes) уточнение невозможно; seek, который бросает,
        # уходит в rescue refine.
        return nil unless io.responds_to?(:size)

        size = io.size.to_i32
        return nil unless size >= EOCD_SIZE

        tail_size = {size, MAX_EOCD_SEARCH}.min
        io.seek(size - tail_size)
        tail = Magic.io_read(io, tail_size)
        return nil unless tail && tail.size == tail_size

        eocd_pos = locate_eocd(tail)
        return nil unless eocd_pos

        parsed = parse_eocd(io, tail, eocd_pos)
        return nil unless parsed
        entries, directory_size, directory_offset = parsed
        return nil unless directory_offset + directory_size <= size

        read_parts(io, entries, directory_size, directory_offset)
      end

      # Scans backward through the file's tail for the end-of-central-directory record,
      # validating each candidate signature against its comment length.
      def self.locate_eocd(tail : Bytes) : Int32?
        pos = tail.size - EOCD_SIZE
        MAX_EOCD_CANDIDATES.times do
          return nil unless pos >= 0 && (pos = rindex_bytes(tail, EOCD_SIGNATURE, pos))
          comment_size = u16(tail, pos + 20)
          return pos if pos + EOCD_SIZE + comment_size == tail.size
          pos -= 1
        end
        nil
      end

      # Returns {entry count, central directory size, central directory offset}, following
      # the Zip64 records when the classic fields overflow. Multi-disk archives and
      # malformed records return nil.
      def self.parse_eocd(io : IO, tail : Bytes, eocd_pos : Int32) : Tuple(Int32, Int32, Int32)?
        base = eocd_pos + 4
        disk = u16(tail, base)
        directory_disk = u16(tail, base + 2)
        entries = u16(tail, base + 6)
        directory_size = u32(tail, base + 8)
        directory_offset = u32(tail, base + 12)
        return nil unless disk == 0 && directory_disk == 0

        if entries == 0xFFFF || directory_size == 0xFFFFFFFF || directory_offset == 0xFFFFFFFF
          parse_zip64_eocd(io, tail, eocd_pos)
        else
          {entries.to_i32, directory_size.to_i32, directory_offset.to_i32}
        end
      end

      def self.parse_zip64_eocd(io : IO, tail : Bytes, eocd_pos : Int32) : Tuple(Int32, Int32, Int32)?
        locator_pos = eocd_pos - ZIP64_EOCD_LOCATOR_SIZE
        return nil if locator_pos < 0 || tail[locator_pos, 4] != ZIP64_EOCD_LOCATOR_SIGNATURE

        locator_disk = u32(tail, locator_pos + 4)
        zip64_eocd_offset = u64(tail, locator_pos + 8)
        total_disks = u16(tail, locator_pos + 16)
        return nil unless locator_disk == 0 && total_disks == 1

        io.seek(zip64_eocd_offset.to_i32)
        record = Magic.io_read(io, ZIP64_EOCD_SIZE)
        return nil unless record && record.size == ZIP64_EOCD_SIZE
        return nil unless record[0, 4] == ZIP64_EOCD_SIGNATURE

        disk = u32(record, 16)
        directory_disk = u32(record, 20)
        entries = u64(record, 32)
        directory_size = u64(record, 40)
        directory_offset = u64(record, 48)
        return nil unless disk == 0 && directory_disk == 0

        {entries.to_i32, directory_size.to_i32, directory_offset.to_i32}
      end

      # Walks central directory entries, collecting the OOXML part names that
      # discriminate between document families. Reads and entry counts are bounded;
      # the walk stops early once a family and its macro part are both seen.
      def self.read_parts(io : IO, entries : Int32, directory_size : Int32, directory_offset : Int32) : Array(String)?
        io.seek(directory_offset)
        directory = Magic.io_read(io, {directory_size, MAX_CENTRAL_DIRECTORY_READ}.min)
        return nil unless directory

        parts = [] of String
        pos = 0
        {entries, MAX_ENTRIES}.min.times do
          break unless pos + CENTRAL_DIRECTORY_HEADER_SIZE <= directory.size &&
                        directory[pos, 4] == CENTRAL_DIRECTORY_SIGNATURE

          name_size = u16(directory, pos + 28)
          extra_size = u16(directory, pos + 30)
          comment_size = u16(directory, pos + 32)
          name_start = pos + CENTRAL_DIRECTORY_HEADER_SIZE
          break unless name_start + name_size <= directory.size
          name = String.new(directory[name_start, name_size])

          parts << name if DISCRIMINATING_PARTS.includes?(name)
          break if complete?(parts)

          pos += CENTRAL_DIRECTORY_HEADER_SIZE + name_size + extra_size + comment_size
        end
        parts
      end

      # A main part plus its macro part is as specific as classification gets.
      def self.complete?(parts : Array(String)) : Bool
        DOCUMENT_FAMILIES.any? do |main_part, macro_part, _, _|
          parts.includes?(main_part) && parts.includes?(macro_part)
        end
      end

      def self.rindex_bytes(hay : Bytes, needle : Bytes, limit : Int32) : Int32?
        start = {limit, hay.size - needle.size}.min
        while start >= 0
          return start if hay[start, needle.size] == needle
          start -= 1
        end
        nil
      end

      def self.u16(bytes : Bytes, pos : Int32) : UInt16
        IO::ByteFormat::LittleEndian.decode(UInt16, bytes[pos, 2])
      end

      def self.u32(bytes : Bytes, pos : Int32) : UInt32
        IO::ByteFormat::LittleEndian.decode(UInt32, bytes[pos, 4])
      end

      def self.u64(bytes : Bytes, pos : Int32) : UInt64
        IO::ByteFormat::LittleEndian.decode(UInt64, bytes[pos, 8])
      end
    end
  end
end
