require "./spec_helper"
require "digest/crc32"

# Порт test/zip_sniffing_test.rb: валидные ZIP-архивы со stored-записями
# собираются вручную, пакинг little-endian как в Ruby-тесте.

OOXML_CONTENT_TYPES = <<-XML
  <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
  <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>
XML

private def put16(io : IO, value : Int) : Nil
  io.write_bytes value.to_u16!, IO::ByteFormat::LittleEndian
end

private def put32(io : IO, value : Int) : Nil
  io.write_bytes value.to_u32!, IO::ByteFormat::LittleEndian
end

private def put64(io : IO, value : Int) : Nil
  io.write_bytes value.to_u64!, IO::ByteFormat::LittleEndian
end

# Builds a valid ZIP archive in memory with stored (uncompressed) entries.
def zip_archive(entries : Hash(String, String), zip64 = false) : String
  io = IO::Memory.new
  directory = IO::Memory.new

  entries.each do |name, data|
    data = data || ""
    offset = io.pos
    crc = Digest::CRC32.checksum(data.to_slice)

    io.write "PK\x03\x04".to_slice
    put16(io, 20)
    put16(io, 0)
    put16(io, 0)
    put16(io, 0)
    put16(io, 0)
    put32(io, crc)
    put32(io, data.bytesize)
    put32(io, data.bytesize)
    put16(io, name.bytesize)
    put16(io, 0)
    io.write name.to_slice
    io.write data.to_slice

    directory.write "PK\x01\x02".to_slice
    put16(directory, 20)
    put16(directory, 20)
    put16(directory, 0)
    put16(directory, 0)
    put16(directory, 0)
    put16(directory, 0)
    put32(directory, crc)
    put32(directory, data.bytesize)
    put32(directory, data.bytesize)
    put16(directory, name.bytesize)
    put16(directory, 0) # extra
    put16(directory, 0) # comment
    put16(directory, 0) # disk number start
    put16(directory, 0) # internal attrs
    put32(directory, 0) # external attrs
    put32(directory, offset)
    directory.write name.to_slice
  end

  directory_offset = io.pos
  io.write directory.to_s.to_slice

  if zip64
    zip64_eocd_offset = io.pos
    io.write "PK\x06\x06".to_slice
    put64(io, 44)
    put16(io, 45)
    put16(io, 45)
    put32(io, 0)
    put32(io, 0)
    put64(io, entries.size)
    put64(io, entries.size)
    put64(io, directory.to_s.bytesize)
    put64(io, directory_offset)

    io.write "PK\x06\x07".to_slice
    put32(io, 0)
    put64(io, zip64_eocd_offset)
    put16(io, 1)

    io.write "PK\x05\x06".to_slice
    put16(io, 0)
    put16(io, 0)
    put16(io, 0xFFFF)
    put16(io, 0xFFFF)
    put32(io, 0xFFFFFFFF)
    put32(io, 0xFFFFFFFF)
    put16(io, 0)
  else
    io.write "PK\x05\x06".to_slice
    put16(io, 0)
    put16(io, 0)
    put16(io, entries.size)
    put16(io, entries.size)
    put32(io, directory.to_s.bytesize)
    put32(io, directory_offset)
    put16(io, 0)
  end

  io.to_s
end

def xlsx_parts : Hash(String, String)
  {
    "[Content_Types].xml" => OOXML_CONTENT_TYPES,
    "_rels/.rels"         => "",
    "xl/workbook.xml"     => "<workbook/>",
  }
end

describe "Marcel::Magic::Zip sniffing" do
  it "spreadsheet with [Content_Types].xml past the 64KB magic ceiling is detected from content" do
    data = zip_archive({"docProps/padding.bin" => "\0" * 80_000}.merge(xlsx_parts))

    (data.byte_index("[Content_Types].xml").not_nil!).should be > 65_536
    Marcel::MimeType.for(IO::Memory.new(data)).should eq(
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  it "word document past the 64KB magic ceiling is detected from content" do
    data = zip_archive({
      "docProps/padding.bin"  => "\0" * 80_000,
      "[Content_Types].xml"   => OOXML_CONTENT_TYPES,
      "word/document.xml"     => "<document/>",
    })

    Marcel::MimeType.for(IO::Memory.new(data)).should eq(
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
  end

  it "presentation past the 64KB magic ceiling is detected from content" do
    data = zip_archive({
      "docProps/padding.bin"  => "\0" * 80_000,
      "[Content_Types].xml"   => OOXML_CONTENT_TYPES,
      "ppt/presentation.xml"  => "<presentation/>",
    })

    Marcel::MimeType.for(IO::Memory.new(data)).should eq(
      "application/vnd.openxmlformats-officedocument.presentationml.presentation")
  end

  it "macro-enabled workbook is detected from content alone" do
    data = zip_archive(xlsx_parts.merge({"xl/vbaProject.bin" => "\x01\x02"}))

    Marcel::MimeType.for(IO::Memory.new(data)).should eq "application/vnd.ms-excel.sheet.macroenabled.12"
  end

  it "macro-enabled word document is detected from content alone" do
    data = zip_archive({
      "[Content_Types].xml" => OOXML_CONTENT_TYPES,
      "word/document.xml"   => "<document/>",
      "word/vbaProject.bin" => "\x01\x02",
    })

    Marcel::MimeType.for(IO::Memory.new(data)).should eq "application/vnd.ms-word.document.macroenabled.12"
  end

  it "macro-enabled presentation is detected from content alone" do
    data = zip_archive({
      "[Content_Types].xml" => OOXML_CONTENT_TYPES,
      "ppt/presentation.xml" => "<presentation/>",
      "ppt/vbaProject.bin"  => "\x01\x02",
    })

    Marcel::MimeType.for(IO::Memory.new(data)).should eq "application/vnd.ms-powerpoint.presentation.macroenabled.12"
  end

  it "macro-enabled template keeps its name-derived type over the content-derived macro type" do
    data = zip_archive(xlsx_parts.merge({"xl/vbaProject.bin" => "\x01\x02"}))

    Marcel::MimeType.for(IO::Memory.new(data), name: "template.xltm").should eq(
      "application/vnd.ms-excel.template.macroenabled.12")
  end

  it "macro-enabled content wins over a non-macro filename" do
    data = zip_archive(xlsx_parts.merge({"xl/vbaProject.bin" => "\x01\x02"}))

    Marcel::MimeType.for(IO::Memory.new(data), name: "innocent.xlsx").should eq(
      "application/vnd.ms-excel.sheet.macroenabled.12")
  end

  it "zip64 archives are refined via the zip64 end-of-central-directory record" do
    data = zip_archive({"docProps/padding.bin" => "\0" * 80_000}.merge(xlsx_parts), zip64: true)

    Marcel::MimeType.for(IO::Memory.new(data)).should eq(
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  it "plain zips are not upgraded" do
    data = zip_archive({"hello.txt" => "hello", "world/notes.txt" => "notes"})

    Marcel::MimeType.for(IO::Memory.new(data)).should eq "application/zip"
  end

  it "truncated archives keep the base type without raising" do
    data = zip_archive({"docProps/padding.bin" => "\0" * 80_000}.merge(xlsx_parts))

    Marcel::MimeType.for(IO::Memory.new(data.byte_slice(0, data.bytesize - 10))).should eq "application/zip"
  end

  it "corrupt central directory keeps the base type without raising" do
    data = zip_archive(xlsx_parts)
    idx = data.byte_index("PK\x01\x02").not_nil!
    bytes = data.to_slice.dup
    4.times { |i| bytes[idx + i] = "XXXX".to_slice[i] }

    Marcel::MimeType.for(IO::Memory.new(String.new(bytes))).should eq(
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  it "partial reads keep prefix-based detection without raising" do
    data = zip_archive(xlsx_parts)

    Marcel::MimeType.for(IO::Memory.new(data.byte_slice(0, 4096))).should eq(
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  it "partial reads of padded archives keep the base type without raising" do
    data = zip_archive({"docProps/padding.bin" => "\0" * 80_000}.merge(xlsx_parts))

    Marcel::MimeType.for(IO::Memory.new(data.byte_slice(0, 4096))).should eq "application/zip"
  end

  it "unseekable IOs keep the base type without raising" do
    data = zip_archive(xlsx_parts.merge({"xl/vbaProject.bin" => "\x01\x02"}))

    Marcel::MimeType.for(RewindOnlyIO.new(data)).should eq(
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  it "adversarial comment full of EOCD signatures gives up in bounded time" do
    data = zip_archive(xlsx_parts) + ("PK\x05\x06" * 20_000)

    started = Time.instant
    Marcel::MimeType.for(IO::Memory.new(data)).should eq(
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    (Time.instant - started).should be < 1.second
  end

  it "existing OOXML fixtures still refine to their own types" do
    {"vnd.openxmlformats-officedocument.spreadsheetml.sheet"          => "xlsx",
     "vnd.openxmlformats-officedocument.wordprocessingml.document"    => "docx",
     "vnd.openxmlformats-officedocument.presentationml.presentation"  => "pptx"}.each do |type, extension|
      fixture = files("magic/application/#{type}/#{type}.#{extension}")
      Marcel::MimeType.for(fixture).should eq "application/#{type}"
    end
  end

  it "refine leaves the IO rewound" do
    data = zip_archive(xlsx_parts)
    io = IO::Memory.new(data)

    Marcel::MimeType.for(io)
    io.pos.should eq 0
  end
end
