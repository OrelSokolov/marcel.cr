require "./spec_helper"

# Порт test/declared_type_test.rb. Проверка Encoding::UTF_8 у результата не
# переносится: Crystal-строки всегда UTF-8.
describe "Marcel::MimeType declared type detection" do
  it "prefers declared type over filename extension" do
    Marcel::MimeType.for(name: "file.txt", declared_type: "text/html").should eq "text/html"
  end

  it "prefers filename extension over binary type" do
    Marcel::MimeType.for(name: "file.txt", declared_type: "application/octet-stream").should eq "text/plain"
  end

  it "defaults to binary if declared type is unrecognized" do
    Marcel::MimeType.for(declared_type: nil).should eq "application/octet-stream"
    Marcel::MimeType.for(declared_type: "").should eq "application/octet-stream"
    Marcel::MimeType.for(declared_type: "unrecognised").should eq "application/octet-stream"
  end

  it "ignores charset declarations" do
    Marcel::MimeType.for(declared_type: "text/html; charset=utf-8").should eq "text/html"
  end

  it "prefers IANA-registered types over deprecated or private-tree aliases" do
    # RFC 9512 registers application/yaml; the x-/text spellings are historical
    Marcel::MimeType.for(declared_type: "application/yaml").should eq "application/yaml"
    Marcel::MimeType.for(declared_type: "text/x-yaml").should eq "application/yaml"
    Marcel::MimeType.for(declared_type: "text/yaml").should eq "application/yaml"
    Marcel::MimeType.for(extension: "yaml").should eq "application/yaml"

    # IANA lists application/x-debian-package as the deprecated alias
    Marcel::MimeType.for(declared_type: "application/x-debian-package").should eq "application/vnd.debian.binary-package"
    Marcel::MimeType.for(extension: "deb").should eq "application/vnd.debian.binary-package"

    # application/xliff+xml has been IANA-registered since 2018
    Marcel::MimeType.for(declared_type: "application/x-xliff+xml").should eq "application/xliff+xml"
    Marcel::MimeType.for(extension: "xlf").should eq "application/xliff+xml"
  end

  it "does not conflate OpenXPS with Microsoft XPS" do
    # IANA notes the two formats are not directly interoperable
    Marcel::MimeType.for(declared_type: "application/oxps").should eq "application/oxps"
    Marcel::MimeType.for(extension: "oxps").should eq "application/oxps"
    Marcel::MimeType.for(extension: "xps").should eq "application/vnd.ms-xpsdocument"

    # Severed in the generated tables themselves, so magic-only loading agrees
    Marcel::EXTENSIONS["oxps"]?.should eq "application/oxps"
    Marcel::Magic.new("application/vnd.ms-xpsdocument").extensions.should eq %w(xps)

    # And re-extending Microsoft XPS cannot reclaim the extension
    Marcel::MimeType.extend "application/vnd.ms-xpsdocument", extensions: %w(xps)
    Marcel::MimeType.for(extension: "oxps").should eq "application/oxps"
  end

  it "resolves declared type aliases to their canonical MIME type" do
    Marcel::MimeType.for(declared_type: "application/javascript").should eq "text/javascript"
    Marcel::MimeType.for(declared_type: "audio/x-aac").should eq "audio/aac"

    Marcel::TYPE_ALIASES.each do |aliased, canonical|
      # Declared types parse down to bare type/subtype, so parameterized aliases
      # resolve through their base type rather than the alias table.
      next if aliased.includes?(";")

      Marcel::MimeType.for(declared_type: aliased).should eq canonical
    end
  end

  it "tolerates a single trailing semicolon" do
    Marcel::MimeType.for(declared_type: "image/jpeg;").should eq "image/jpeg"
    Marcel::MimeType.for(declared_type: "text/html; charset=utf-8; ").should eq "text/html"
  end

  it "normalizes case and surrounding HTTP whitespace" do
    Marcel::MimeType.for(declared_type: " \tTEXT/HTML\r\n").should eq "text/html"
    Marcel::MimeType.for(name: "file.txt", declared_type: " text/html").should eq "text/html"
  end

  it "accepts valid media type tokens" do
    Marcel::MimeType.for(declared_type: "APPLICATION/VND.EXAMPLE+JSON").should eq "application/vnd.example+json"
  end

  it "allows commas in quoted parameters" do
    Marcel::MimeType.for(declared_type: %(text/html; example="one,two")).should eq "text/html"
    Marcel::MimeType.for(declared_type: %(text/html; example="one\\",two")).should eq "text/html"
  end

  it "ignores malformed media types" do
    malformed_types = [
      "/html",
      "text/",
      "text/ html",
      "text/html garbage",
      "text/html\0garbage",
      "text/html/extra",
      "text/{html",
      "tëxt/html",
      "\vtext/html",
      "\ftext/html",
      "text/html;;charset=utf-8",
      "text/html; ; charset=utf-8",
      %(text/html; example=foo", image/png"),
      %(text/html; example="unterminated),
      %(text/html; example=foo\0bar),
    ]

    malformed_types.each do |declared_type|
      Marcel::MimeType.for(declared_type: declared_type).should(
        eq("application/octet-stream"), "Expected #{declared_type.inspect} to be ignored")

      Marcel::MimeType.for(name: "file.txt", declared_type: declared_type).should(
        eq("text/plain"), "Expected #{declared_type.inspect} to fall back to the filename")
    end
  end

  it "ignores comma-separated media type lists" do
    ["text/html, image/png", "image/png, text/html", "invalid, text/html"].each do |declared_type|
      Marcel::MimeType.for(declared_type: declared_type).should(
        eq("application/octet-stream"), "Expected #{declared_type.inspect} to be ignored")

      Marcel::MimeType.for(name: "file.txt", declared_type: declared_type).should(
        eq("text/plain"), "Expected #{declared_type.inspect} to fall back to the filename")
    end
  end

  it "normalizes binary type before treating it as undeclared" do
    Marcel::MimeType.for(
      name: "file.txt", declared_type: " \tAPPLICATION/OCTET-STREAM ; example=value\r\n"
    ).should eq "text/plain"
  end

  it "ignores invalidly encoded declared types without raising" do
    invalid_type = String.new("text/html".to_slice + Bytes[0xFF])

    Marcel::MimeType.for(declared_type: invalid_type).should eq "application/octet-stream"
    Marcel::MimeType.for(name: "file.txt", declared_type: invalid_type).should eq "text/plain"
  end

  it "returns well-formed unknown declared types as labels" do
    Marcel::MimeType.for(name: "file.html", declared_type: "APPLICATION/X-EVIL").should eq "application/x-evil"
  end

  it "bounds declared type metadata" do
    prefix = "application/"
    maximum = prefix + ("a" * (Marcel::MimeType::MAX_DECLARED_TYPE_BYTES - prefix.bytesize))
    oversized = maximum + "a"

    Marcel::MimeType.for(declared_type: maximum).should eq maximum
    Marcel::MimeType.for(declared_type: oversized).should eq "application/octet-stream"
    Marcel::MimeType.for(name: "file.txt", declared_type: oversized).should eq "text/plain"
  end
end
