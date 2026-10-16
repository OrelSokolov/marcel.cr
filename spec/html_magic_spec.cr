require "./spec_helper"

# Порт test/html_magic_test.rb. Тест «standalone Magic» с Ruby-подпроцессом не
# переносится (проверяет require-изоляцию Ruby-гема).

def midi_with_text_event(text : String) : String
  track = IO::Memory.new
  track.write Bytes[0x00, 0xFF, 0x01]
  track.write_byte text.bytesize.to_u8!
  track.write text.to_slice
  track.write Bytes[0x00, 0xFF, 0x2F, 0x00]
  t = track.to_s

  io = IO::Memory.new
  io.write "MThd".to_slice
  io.write_bytes 6u32, IO::ByteFormat::BigEndian
  io.write_bytes 0u16, IO::ByteFormat::BigEndian
  io.write_bytes 1u16, IO::ByteFormat::BigEndian
  io.write_bytes 96u16, IO::ByteFormat::BigEndian
  io.write "MTrk".to_slice
  io.write_bytes t.bytesize.to_u32!, IO::ByteFormat::BigEndian
  io.write t.to_slice
  io.to_s
end

describe "Marcel::MimeType HTML magic" do
  it "does not override strong binary magic with a closing HTML tag" do
    fixtures = {
      "magic/image/jpeg/jpeg.jpg"        => "image/jpeg",
      "magic/image/png/png.png"          => "image/png",
      "magic/image/gif/gif.gif"          => "image/gif",
      "magic/application/pdf/pdf.pdf"    => "application/pdf",
      "magic/application/zip/zip.zip"    => "application/zip",
    }

    fixtures.each do |fixture, content_type|
      polyglot = IO::Memory.new(File.read(fixture_path(fixture)) + "\n</html>\n")

      Marcel::MimeType.for(polyglot).should(
        eq(content_type), "Expected #{fixture} magic to take precedence over a closing HTML tag")
    end
  end

  it "does not classify a comment-prefixed PDF ending in an HTML tag as HTML" do
    polyglot = IO::Memory.new(
      "<!-- leading comment -->\n" + File.read(fixture_path("magic/application/pdf/pdf.pdf")) + "\n</html>\n"
    )

    Marcel::MimeType.for(polyglot).should_not eq "text/html"
  end

  it "recognizes an HTML document at the start of the data" do
    Marcel::MimeType.for(IO::Memory.new("<html><body>hello</body>")).should eq "text/html"
  end

  it "does not recognize an HTML tag at an arbitrary exact offset" do
    Marcel::MimeType.for(IO::Memory.new(("x" * 64) + "<html>")).should eq "application/octet-stream"
  end

  it "recognizes HTML after leading comments in a partial read" do
    html = "<!-- #{"x" * 512} -->\n<html><body>#{"x" * 5_000}</body></html>"
    chunk = html.byte_slice(0, 4_096)

    Marcel::MimeType.for(IO::Memory.new(chunk), name: "page.html", declared_type: "text/html").should eq "text/html"
  end

  it "recognizes HTML with a byte order mark" do
    html = "\xEF\xBB\xBF<html><body>hello</body>"

    Marcel::MimeType.for(IO::Memory.new(html)).should eq "text/html"
  end

  it "recognizes HTML after an XML declaration in a partial read" do
    html = %(<?xml version="1.0"?>\n<html><body>#{"x" * 5_000}</body></html>)
    chunk = html.byte_slice(0, 4_096)

    Marcel::MimeType.for(IO::Memory.new(chunk), name: "page.html", declared_type: "text/html").should eq "text/html"
  end

  it "keeps XHTML with its namespace as XHTML" do
    documents = [
      %(<html xmlns="http://www.w3.org/1999/xhtml"><body></body></html>),
      %(<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body></body></html>),
      %(<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"><html xmlns="http://www.w3.org/1999/xhtml"><body></body></html>),
      %(<!DOCTYPE html><!-- comment --><html xmlns="http://www.w3.org/1999/xhtml"><body></body></html>),
      %(<!DOCTYPE html><!-- one --><!-- two --><html xmlns="http://www.w3.org/1999/xhtml"><body></body></html>),
      %(<?xml version="1.0"?><!-- before --><!DOCTYPE html><!-- after --><html xmlns="http://www.w3.org/1999/xhtml"><body></body></html>),
    ]

    documents.each do |document|
      Marcel::MimeType.for(IO::Memory.new(document)).should eq "application/xhtml+xml"
    end
  end

  it "does not recognize XHTML from a loose namespace substring" do
    documents = [
      %(<!DOCTYPE html><!-- comment --><html xmlns="urn:not-xhtml"></html>),
    ]
    documents.concat [1, 4_097, 8_192].map { |offset| ("x" * offset) + %(<html xmlns="urn:not-xhtml"></html>) }

    documents.each_with_index do |document, index|
      types = Marcel::Magic.all_by_magic(IO::Memory.new(document)).map(&.type)

      types.should_not contain("application/xhtml+xml"), "Unexpected XHTML match for document #{index}"
    end
  end

  it "matches XHTML names and namespace case-sensitively" do
    documents = [
      %(<HTML xmlns="http://www.w3.org/1999/xhtml"></HTML>),
      %(<html XMLNS="http://www.w3.org/1999/xhtml"></html>),
      %(<html xmlns="http://www.w3.org/1999/XHTML"></html>),
    ]

    documents.each do |document|
      types = Marcel::Magic.all_by_magic(IO::Memory.new(document)).map(&.type)

      types.should_not contain "application/xhtml+xml"
    end
  end

  it "does not recognize XHTML from namespace text inside another attribute" do
    documents = [
      %q(<html title=' xmlns="http://www.w3.org/1999/xhtml" '></html>),
      %q(<html title=" xmlns='http://www.w3.org/1999/xhtml' "></html>),
    ]

    documents.each do |document|
      types = Marcel::Magic.all_by_magic(IO::Memory.new(document)).map(&.type)

      types.should_not contain "application/xhtml+xml"
    end
  end

  it "recognizes XHTML when its namespace follows other attributes" do
    document = %(<html lang="en" xml:lang="en" xmlns="http://www.w3.org/1999/xhtml"></html>)

    Marcel::MimeType.for(IO::Memory.new(document)).should eq "application/xhtml+xml"
  end

  it "does not classify valid MIDI text events as XHTML" do
    namespaces = ["urn:not-xhtml", "http://www.w3.org/1999/xhtml"]

    namespaces.each do |namespace|
      midi = midi_with_text_event(%(<html xmlns="#{namespace}"></html>))

      Marcel::MimeType.for(IO::Memory.new(midi)).should eq "audio/midi"
      Marcel::Magic.all_by_magic(IO::Memory.new(midi)).map(&.type).should_not contain "application/xhtml+xml"
    end
  end

  it "preserves XHTML filename extensions" do
    %w(page.xht page.xhtml page.xhtml2).each do |name|
      Marcel::MimeType.for(name: name).should eq "application/xhtml+xml"
    end
  end

  it "recognizes HTML containing SVG after a leading comment" do
    html = %(<!-- leading comment -->\n<html><body><svg><script></script></svg>)

    Marcel::MimeType.for(IO::Memory.new(html)).should eq "text/html"
  end

  it "recognizes HTML after many comments without pathological backtracking" do
    html = ("<!--x-->" * 400) + "<html><body></body></html>"

    started = Time.instant
    content_type = Marcel::MimeType.for(IO::Memory.new(html))
    elapsed = Time.instant - started

    elapsed.should be < 5.seconds
    content_type.should eq "text/html"
  end

  it "keeps a comment-prefixed SVG as SVG" do
    svg = %(<!-- leading comment -->\n<svg xmlns="http://www.w3.org/2000/svg"></svg>)

    Marcel::MimeType.for(IO::Memory.new(svg)).should eq "image/svg+xml"
  end

  it "recognizes SVG after a short XML declaration" do
    svg = %(<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"></svg>)

    Marcel::MimeType.for(IO::Memory.new(svg)).should eq "image/svg+xml"
  end

  it "does not promote generic XML to HTML from hints" do
    documents = [
      %(<?xml version="1.0"?><root></root>),
      %(<!-- leading comment --><root></root>),
    ]

    documents.each do |document|
      Marcel::MimeType.for(IO::Memory.new(document), name: "page.html", declared_type: "text/html").should eq "application/xml"
    end
  end

  it "does not treat a partial prefix as the end of a long HTML document" do
    # Past the HTML magic window, the root element scan still finds <html> within its own
    # 64KB bound; a prefix cut before the root element, or a root beyond that bound, is not HTML.
    html = %(<!-- #{"x" * 5_000} -->\n<html><body></body></html>)
    chunk = html.byte_slice(0, 4_096)
    distant = %(<!-- #{"x" * 70_000} -->\n<html><body></body></html>)

    Marcel::MimeType.for(IO::Memory.new(html)).should eq "text/html"
    Marcel::MimeType.for(IO::Memory.new(chunk)).should eq "application/xml"
    Marcel::MimeType.for(IO::Memory.new(distant)).should eq "application/xml"
  end
end
