require "./spec_helper"

# Порт test/xml_sniffing_test.rb. Ruby-кодировки (.encode(Shift_JIS/UTF-16))
# заменены прямыми байтовыми литералами: ソ = 83 5C (младший байт — ASCII
# backslash), ‐ (U+2010) = 81 5D, あ = 82 A0.

DECLARATION = %(<?xml version="1.0" encoding="UTF-8"?>)
MAX_SCAN = Marcel::Magic::Xml::MAX_SCAN

def detect(data : String, name : String? = nil, declared_type : String? = nil) : String
  Marcel::MimeType.for(IO::Memory.new(data), name: name, declared_type: declared_type)
end

def xml(body : String) : String
  "#{DECLARATION}\n#{body}"
end

def encode_utf16(s : String, big_endian : Bool) : String
  io = IO::Memory.new
  io.write big_endian ? Bytes[0xFE, 0xFF] : Bytes[0xFF, 0xFE]
  s.each_char do |char|
    cp = char.ord
    if cp >= 0x10000
      cp -= 0x10000
      write_utf16_unit(io, 0xD800 + (cp >> 10), big_endian)
      write_utf16_unit(io, 0xDC00 + (cp & 0x3FF), big_endian)
    else
      write_utf16_unit(io, cp, big_endian)
    end
  end
  io.to_s
end

def write_utf16_unit(io : IO::Memory, unit : Int32, big_endian : Bool) : Nil
  if big_endian
    io.write_byte (unit >> 8).to_u8!
    io.write_byte unit.to_u8!
  else
    io.write_byte unit.to_u8!
    io.write_byte (unit >> 8).to_u8!
  end
end

def utf16le(s : String) : String
  encode_utf16(s, big_endian: false)
end

def utf16be(s : String) : String
  encode_utf16(s, big_endian: true)
end

describe "Marcel::Magic::Xml sniffing" do
  it "RSS feeds are detected from content" do
    detect(xml(%(<rss version="2.0"><channel><title>t</title></channel></rss>))).should eq "application/rss+xml"
  end

  it "Atom feeds are detected from content under both namespaces" do
    detect(xml(%(<feed xmlns="http://www.w3.org/2005/Atom"><title>t</title></feed>))).should eq "application/atom+xml"
    detect(xml(%(<feed xmlns="http://purl.org/atom/ns#" version="0.3"><title>t</title></feed>))).should eq "application/atom+xml"
  end

  it "KML is detected bare, under every namespace, and with a prefixed root" do
    detect(xml(%(<kml><Placemark/></kml>))).should eq "application/vnd.google-earth.kml+xml"

    %w(http://www.opengis.net/kml/2.2 http://earth.google.com/kml/2.0
       http://earth.google.com/kml/2.1 http://earth.google.com/kml/2.2).each do |namespace|
      detect(xml(%(<kml xmlns="#{namespace}"><Placemark/></kml>))).should eq "application/vnd.google-earth.kml+xml"
    end

    detect(xml(%(<k:kml xmlns:k="http://www.opengis.net/kml/2.2"><k:Placemark/></k:kml>))).should(
      eq "application/vnd.google-earth.kml+xml")
  end

  it "XHTML with a prefixed root is detected by namespace" do
    detect(xml(%(<h:html xmlns:h="http://www.w3.org/1999/xhtml"><h:body/></h:html>))).should eq "application/xhtml+xml"
  end

  it "property lists are detected past their DOCTYPE" do
    plist = %(<?xml version="1.0" encoding="UTF-8"?>\n) +
            %(<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n) +
            %(<plist version="1.0">\n) +
            %(<dict><key>Name</key><string>Marcel</string></dict>\n) +
            %(</plist>\n)

    detect(plist).should eq "application/x-plist"
  end

  it "XSLT stylesheets are detected by namespace" do
    detect(xml(%(<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"/>))).should(
      eq "application/xslt+xml")
  end

  it "ONIX collisions resolve to the first type by name, as Tika does" do
    detect(xml(%(<ONIXMessage xmlns="http://ns.editeur.org/onix/3.0/reference" release="3.0"/>))).should(
      eq "application/onix-message+xml")
    detect(xml(%(<ONIXMessage release="3.0"/>))).should eq "application/onix-message+xml"
  end

  it "iWork flat XML documents are detected by namespace" do
    detect(xml(%(<sl:document xmlns:sl="http://developer.apple.com/namespaces/sl"/>))).should eq "application/vnd.apple.pages"
    detect(xml(%(<ls:document xmlns:ls="http://developer.apple.com/namespaces/ls"/>))).should eq "application/vnd.apple.numbers"
    detect(xml(%(<key:presentation xmlns:key="http://developer.apple.com/namespaces/keynote2"/>))).should eq "application/vnd.apple.keynote"
  end

  it "Office 2003 XML documents are detected past their application processing instruction" do
    word = xml(<<-XML)
      <?mso-application progid="Word.Document"?>
      <w:wordDocument xmlns:w="http://schemas.microsoft.com/office/word/2003/wordml"><w:body/></w:wordDocument>
    XML
    excel = xml(<<-XML)
      <?mso-application progid="Excel.Sheet"?>
      <Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"><Worksheet/></Workbook>
    XML

    detect(word).should eq "application/vnd.ms-wordml"
    detect(excel).should eq "application/vnd.ms-spreadsheetml"
  end

  it "aliased table values are canonicalized" do
    Marcel::ROOT_XML[{"urn:oasis:names:tc:xliff:document:1.2", "xliff"}]?.should eq "application/x-xliff+xml"
    detect(xml(%(<xliff xmlns="urn:oasis:names:tc:xliff:document:1.2" version="1.2"/>))).should eq "application/xliff+xml"
  end

  it "un-namespaced HTML fragment roots are HTML, as Tika labels them" do
    %w(body p script frameset iframe link BODY P SCRIPT).each do |root|
      detect(xml("<#{root}>x</#{root}>")).should(eq("text/html"), root)
    end
  end

  it "unknown and namespaced-but-unlisted roots keep the generic type" do
    detect(xml(%(<manifest xmlns="urn:example:manifest"/>))).should eq "application/xml"
    detect(xml(%(<rss xmlns="urn:example:not-rss" version="2.0"/>))).should eq "application/xml"
    detect(xml(%(<body xmlns="urn:example:not-html"/>))).should eq "application/xml"
  end

  it "documents without a declaration or leading comment never reach the sniffer" do
    detect(%(<rss version="2.0"><channel/></rss>)).should eq "application/octet-stream"
  end

  it "a leading comment still reaches the root element" do
    detect(%(<!-- generated by a feed builder -->\n<rss version="2.0"><channel/></rss>)).should eq "application/rss+xml"
    detect(xml(%(<!-- one -->\n<!-- two\n spans lines -->\n<feed xmlns="http://www.w3.org/2005/Atom"/>))).should eq "application/atom+xml"
  end

  it "internal DTD subsets containing quoted markup and comments do not end the prolog early" do
    document = xml(<<-XML)
      <!DOCTYPE rss [
        <!ENTITY brand "<b>Acme</b>">
        <!ENTITY quote '"quoted"'>
        <!-- don't stop here > -->
        <?pi with > inside?>
        <!ELEMENT rss (channel)>
      ]>
      <rss version="2.0"><channel><title>&brand;</title></channel></rss>
    XML

    detect(document).should eq "application/rss+xml"
  end

  it "attribute values containing angle brackets do not truncate the start-tag" do
    detect(xml(%(<rss version="2.0" note="a > b"><channel/></rss>))).should eq "application/rss+xml"
    detect(xml(%(<kml note='x > y' xmlns="http://www.opengis.net/kml/2.2"/>))).should eq "application/vnd.google-earth.kml+xml"
  end

  it "start-tags spanning lines and non-ASCII attribute names are read" do
    detect(xml(%(<feed\n    xml:lang="en"\n\ttítulo="x"\n    xmlns="http://www.w3.org/2005/Atom"\n>\n</feed>))).should(
      eq "application/atom+xml")
  end

  it "an empty xmlns declaration puts the root in no namespace" do
    detect(xml(%(<rss xmlns="" version="2.0"/>))).should eq "application/rss+xml"
  end

  it "byte order marks are honoured" do
    utf8 = "\xEF\xBB\xBF" + xml(%(<rss version="2.0"/>))
    utf16le_doc = utf16le(xml(%(<rss version="2.0"/>)))
    utf16be_doc = utf16be(xml(%(<feed xmlns="http://www.w3.org/2005/Atom"/>)))

    detect(utf8).should eq "application/rss+xml"
    detect(utf16le_doc).should eq "application/rss+xml"
    detect(utf16be_doc).should eq "application/atom+xml"
  end

  it "odd-length UTF-16 truncation is harmless after the root and fail-closed within it" do
    document = utf16le(xml(%(<rss version="2.0"><channel><title>feed</title></channel></rss>)))
    root_start = document.byte_index(String.new(Bytes[0x3C, 0x00, 0x72, 0x00, 0x73, 0x00, 0x73, 0x00])).not_nil!
    root_end = document.byte_index(String.new(Bytes[0x3E, 0x00]), root_start).not_nil! + 2

    detect(document.byte_slice(0, root_end + 7)).should eq "application/rss+xml"
    detect(document.byte_slice(0, root_end - 3)).should eq "application/xml"
  end

  it "a start-tag truncated by the scan limit keeps the generic type" do
    prolog = DECLARATION + "<!--" + ("x" * (MAX_SCAN - DECLARATION.bytesize - 20)) + "-->"
    document = prolog + %(<rss version="2.0"><channel/></rss>)

    (document.byte_index("<rss").not_nil!).should be < MAX_SCAN
    (document.byte_index("<rss").not_nil! + %(<rss version="2.0">).bytesize).should be > MAX_SCAN
    detect(document).should eq "application/xml"
  end

  it "a root element beyond the scan limit keeps the generic type" do
    document = DECLARATION + "<!--" + ("x" * MAX_SCAN) + %(--><rss version="2.0"/>)

    detect(document).should eq "application/xml"
  end

  it "malformed prologs keep the generic type" do
    detect(DECLARATION).should eq "application/xml"
    detect(xml(%(garbage <rss version="2.0"/>))).should eq "application/xml"
    detect(xml(%(<!-- unterminated <rss version="2.0"/>))).should eq "application/xml"
    detect(xml(%(<!DOCTYPE rss [ <!ENTITY x "unterminated> ]><rss/>))).should eq "application/xml"
    detect(xml(%(<rss version="2.0" <channel/></rss>))).should eq "application/xml"
    detect(xml(%(<k:kml><k:Placemark/></k:kml>))).should eq "application/xml"
  end

  it "deliberately unsupported XML semantics keep the generic type rather than guessing" do
    detect(xml(%(<feed xmlns="http://www.w3.org/2005/&#65;tom"/>))).should eq "application/xml"
    detect(xml(%(<!DOCTYPE feed [<!ATTLIST feed xmlns CDATA #FIXED "http://www.w3.org/2005/Atom">]><feed/>))).should eq "application/xml"
    detect(xml(%(<feed xmlns="http://www.w3.org/2005/\nAtom"/>))).should eq "application/xml"
  end

  it "bytes invalid in the document encoding keep the generic type wherever they fall before the root" do
    detect(xml(%(<!-- \xFF --><rss version="2.0"/>))).should eq "application/xml"
    detect(xml(%(<!-- \xFF --><body/>))).should eq "application/xml"
    detect(xml(%(<rss version="2.0" note="\xFF"/>))).should eq "application/xml"
    detect(%(<?xml version="1.0" encoding="Shift_JIS"?><!-- \x82 --><rss/>)).should eq "application/xml"

    lone_surrogate = utf16le(xml(%(<!-- X --><rss/>)))
    idx = lone_surrogate.byte_index(String.new(Bytes[0x58, 0x00])).not_nil!
    bytes = lone_surrogate.to_slice.dup
    bytes[idx] = 0x00_u8
    bytes[idx + 1] = 0xD8_u8
    detect(String.new(bytes)).should eq "application/xml"
  end

  it "declared encodings are validated as declared, not assumed to be UTF-8" do
    detect(%(<?xml version="1.0" encoding="ISO-8859-1"?><!-- caf\xE9 --><rss/>)).should eq "application/rss+xml"
    detect(%(<?xml version="1.0" encoding="Shift_JIS"?><!-- \x82\xA0 --><rss/>)).should eq "application/rss+xml"
    detect(%(<?xml version="1.0" encoding="utf-8"?><!-- café --><rss/>)).should eq "application/rss+xml"
    detect(%(<?xml version="1.0" encoding="x-unknown"?><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.0" encoding="locale"?><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.0" encoding="UTF-16"?><rss/>)).should eq "application/xml"
  end

  it "legacy multibyte encodings whose trail bytes look like ASCII are read as characters" do
    # Shift_JIS ソ is 83 5C — its trail byte is an ASCII backslash — and ‐ is 81 5D,
    # trailing in an ASCII ], so a raw byte scan would derail inside a name, a value,
    # or a DOCTYPE internal subset.
    sjis_decl = %(<?xml version="1.0" encoding="Shift_JIS"?>)

    detect("#{sjis_decl}<rss \x83\x5C=\"1\"/>").should eq "application/rss+xml"
    detect("#{sjis_decl}<rss note=\"\x83\x5C\"/>").should eq "application/rss+xml"
    detect("#{sjis_decl}<!DOCTYPE rss [<!-- \x81\x5D -->]><rss/>").should eq "application/rss+xml"
    detect("#{sjis_decl}<!-- \x83\x5C --><rss/>").should eq "application/rss+xml"

    # Bytes invalid in the declared encoding stay fatal before the root and harmless after.
    detect("#{sjis_decl}<rss note=\"\x82\"/>").should eq "application/xml"
    detect("#{sjis_decl}<rss/>\x82").should eq "application/rss+xml"
  end

  it "declared US-ASCII rejects high bytes before the root and ignores them after" do
    detect(%(<?xml version="1.0" encoding="US-ASCII"?><rss/>)).should eq "application/rss+xml"
    detect(%(<?xml version="1.0" encoding="US-ASCII"?><!-- caf\xE9 --><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.0" encoding="US-ASCII"?><rss/>\xE9)).should eq "application/rss+xml"
  end

  it "a legacy multibyte character split by the scan limit is harmless after the root" do
    document = %(<?xml version="1.0" encoding="Shift_JIS"?><rss/>)
    document += "x" * (MAX_SCAN - document.bytesize - 1) + "\x83\x5C"

    document.bytesize.should be > MAX_SCAN
    detect(document).should eq "application/rss+xml"
  end

  it "encoding is validated only over the bytes consumed up to the root start-tag" do
    detect(xml(%(<rss version="2.0"><!-- \xFF --></rss>))).should eq "application/rss+xml"

    split_pair = utf16le(xml(%(<rss/>)) + "\u{1F600}")
    detect(split_pair.byte_slice(0, split_pair.bytesize - 2)).should eq "application/rss+xml"
    detect(utf16be(xml(%(<!-- \u{1F600} --><rss/>)))).should eq "application/rss+xml"
  end

  it "prolog markup a SAX parser rejects keeps the generic type" do
    detect(%(<?XML version="1.0"?><rss/>)).should eq "application/xml"
    detect(%(<?xml encoding="UTF-8"?><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.0"?><?xml version="1.0"?><rss/>)).should eq "application/xml"
    detect(%(<!-- first -->#{DECLARATION}<rss/>)).should eq "application/xml"
    detect(xml(%(<?XmL-ish only the exact xml target is reserved?><rss/>))).should eq "application/rss+xml"
    detect(xml(%(<!-- a -- b --><rss/>))).should eq "application/xml"
    detect(xml(%(<!-- ends with hyphen ---><rss/>))).should eq "application/xml"
    detect(xml(%(<!DOCTYPE rss [ <!-- a -- b --> ]><rss/>))).should eq "application/xml"
    detect(xml(%(<?xml-stylesheet href="s.xsl"?><rss/>))).should eq "application/rss+xml"
  end

  it "the XML declaration is parsed in full, not by prefix" do
    # Trailing or duplicated declaration tokens must not hide behind the PI skipper.
    detect(%(<?xml version="1.0" garbage?><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.0"garbage?><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.0" standalone="maybe"?><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.0" encoding="UTF-8" encoding="Shift_JIS"?><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.0" standalone="no" encoding="UTF-8"?><rss/>)).should eq "application/xml"

    detect(%(<?xml version="1.0" standalone="yes"?><rss/>)).should eq "application/rss+xml"
    detect(%(<?xml version="1.0" encoding="UTF-8" standalone="no"?><rss/>)).should eq "application/rss+xml"
    detect(%(<?xml version = "1.0" ?><rss/>)).should eq "application/rss+xml"
  end

  it "duplicate attributes on the root refine nothing" do
    detect(xml(%(<rss xmlns="urn:not-rss" xmlns="" version="2.0"/>))).should eq "application/xml"
    detect(xml(%(<feed xmlns="http://www.w3.org/2005/Atom" xmlns="http://www.w3.org/2005/Atom"/>))).should eq "application/xml"
    detect(xml(%(<k:kml xmlns:k="http://www.opengis.net/kml/2.2" xmlns:k="http://www.opengis.net/kml/2.2"/>))).should eq "application/xml"
  end

  it "namespace-aware attribute validation matches SAX" do
    detect(xml(%(<rss xmlns:a="urn:x" xmlns:b="urn:x" a:x="1" b:x="2"/>))).should eq "application/xml"
    detect(xml(%(<rss p:x="1"/>))).should eq "application/xml"
    detect(xml(%(<rss a:b:c="1"/>))).should eq "application/xml"
    detect(xml(%(<rss note="a<b"/>))).should eq "application/xml"

    detect(xml(%(<rss xmlns:a="urn:x" xmlns:b="urn:y" a:x="1" b:x="2"/>))).should eq "application/rss+xml"
    detect(xml(%(<rss xml:lang="en" version="2.0"/>))).should eq "application/rss+xml"
  end

  it "reserved xml and xmlns bindings are enforced" do
    detect(xml(%(<rss xmlns:xml="urn:x"/>))).should eq "application/xml"
    detect(xml(%(<rss xmlns:xmlns="urn:x"/>))).should eq "application/xml"
    detect(xml(%(<rss xmlns:a="http://www.w3.org/XML/1998/namespace"/>))).should eq "application/xml"
    detect(xml(%(<rss xmlns="http://www.w3.org/2000/xmlns/"/>))).should eq "application/xml"
    detect(xml(%(<rss xmlns:a=""/>))).should eq "application/xml"

    detect(xml(%(<rss xmlns:xml="http://www.w3.org/XML/1998/namespace"/>))).should eq "application/rss+xml"
  end

  it "malformed references in attribute values refine nothing" do
    detect(xml(%(<rss note="a&b"/>))).should eq "application/xml"
    detect(xml(%(<rss note="a&#xZZ;b"/>))).should eq "application/xml"

    detect(xml(%(<rss note="a&amp;b"/>))).should eq "application/rss+xml"
    detect(xml(%(<rss note="&#65;&#x41;"/>))).should eq "application/rss+xml"
  end

  it "processing instruction data must be separated from its target by whitespace" do
    detect(xml(%(<?pi?x?><rss/>))).should eq "application/xml"

    detect(xml(%(<?pi?><rss/>))).should eq "application/rss+xml"
    detect(xml(%(<?pi data?><rss/>))).should eq "application/rss+xml"
  end

  it "only SAX-supported XML versions are recognized" do
    detect(%(<?xml version="1.9"?><rss/>)).should eq "application/xml"

    detect(%(<?xml version="1.1"?><rss/>)).should eq "application/rss+xml"
  end

  it "characters the XML version forbids as literals refine nothing wherever they fall" do
    detect(xml(%(<!-- \x00 --><rss/>))).should eq "application/xml"
    detect(xml(%(<rss note="a\x01b"/>))).should eq "application/xml"
    detect(xml(%(<!-- \x01 --><rss/>))).should eq "application/xml"

    # XML 1.1 restricts the C0 and C1 controls to character references; XML 1.0 forbids
    # C0 outright but admits literal C1. Comments may contain a raw < under both.
    detect(%(<?xml version="1.1"?><!-- \x01 --><rss/>)).should eq "application/xml"
    detect(%(<?xml version="1.1"?><!-- \u{80} --><rss/>)).should eq "application/xml"
    detect(xml(%(<!-- \u{80} --><rss/>))).should eq "application/rss+xml"
    detect(xml(%(<!-- a < b --><rss/>))).should eq "application/rss+xml"
  end

  it "character references must denote characters the XML version admits" do
    detect(xml(%(<rss note="&#1;"/>))).should eq "application/xml"
    detect(%(<?xml version="1.1"?><rss note="&#0;"/>)).should eq "application/xml"
    detect(xml(%(<rss note="&#xD800;"/>))).should eq "application/xml"
    detect(xml(%(<rss note="&#x110000;"/>))).should eq "application/xml"
    detect(xml(%(<rss note="&#xFFFE;"/>))).should eq "application/xml"

    # XML 1.1 admits as references the controls it forbids as literals.
    detect(%(<?xml version="1.1"?><rss note="&#1;"/>)).should eq "application/rss+xml"
    detect(xml(%(<rss note="&#x10FFFF;"/>))).should eq "application/rss+xml"
  end

  it "character references admit unlimited leading zeros" do
    detect(xml(%(<rss note="&#00000009;"/>))).should eq "application/rss+xml"
    detect(xml(%(<rss note="&#x000000041;"/>))).should eq "application/rss+xml"
    detect(%(<?xml version="1.1"?><rss note="&#00000001;"/>)).should eq "application/rss+xml"

    detect(xml(%(<rss note="&#00000001;"/>))).should eq "application/xml"
    detect(xml(%(<rss note="&#00000000;"/>))).should eq "application/xml"
    detect(%(<?xml version="1.1"?><rss note="&#x0000;"/>)).should eq "application/xml"
    detect(xml(%(<rss note="&#000000000000001114112;"/>))).should eq "application/xml"
    detect(xml(%(<rss note="&#99999999999999999999;"/>))).should eq "application/xml"
    detect(xml(%(<rss note="&#x00110000;"/>))).should eq "application/xml"
  end

  it "PI targets and entity names admit the full XML Name grammar, colon included" do
    detect(xml(%(<?p:x?><rss/>))).should eq "application/rss+xml"
    detect(xml(%(<!DOCTYPE rss [<!ENTITY p:x "y">]>\n<rss note="&p:x;"/>))).should eq "application/rss+xml"

    detect(xml(%(<rss note="&p:x;"/>))).should eq "application/xml"
  end

  it "entity references must be predefined unless a DTD could have declared them" do
    detect(xml(%(<rss note="&nbsp;"/>))).should eq "application/xml"

    detect(xml(%(<rss note="&quot;&apos;&lt;&gt;&amp;"/>))).should eq "application/rss+xml"
    detect(xml(%(<!DOCTYPE rss [<!ENTITY nbsp "&#xA0;">]>\n<rss note="&nbsp;"/>))).should eq "application/rss+xml"
  end

  it "names are validated as Unicode names, not as arbitrary high bytes" do
    # U+00B7 is NameChar but not NameStartChar, while U+00E9 starts a name.
    detect(xml(%(<rss ·note="1"/>))).should eq "application/xml"
    detect(xml(%(<rss xmlns:·p="urn:x"/>))).should eq "application/xml"
    detect(xml(%(<·rss/>))).should eq "application/xml"
    detect(xml(%(<?·pi ?><rss/>))).should eq "application/xml"
    detect(xml(%(<rss note="&·e;"/>))).should eq "application/xml"

    detect(xml(%(<rss café="1"/>))).should eq "application/rss+xml"
    detect(xml(%(<?café-pi ?><rss/>))).should eq "application/rss+xml"
  end

  it "XML 1.1 permits prefix undeclaration where 1.0 does not" do
    detect(%(<?xml version="1.1"?><rss xmlns:p=""/>)).should eq "application/rss+xml"

    detect(xml(%(<rss xmlns:p=""/>))).should eq "application/xml"
    detect(%(<?xml version="1.1"?><p:rss xmlns:p=""/>)).should eq "application/xml"
    detect(%(<?xml version="1.1"?><rss xmlns:xml=""/>)).should eq "application/xml"
  end

  it "unseekable but rewindable IOs are refined" do
    Marcel::MimeType.for(RewindOnlyIO.new(xml(%(<rss version="2.0"/>)))).should eq "application/rss+xml"
  end

  it "empty and whitespace-only content is untouched" do
    detect("").should eq "application/octet-stream"
    detect("   \n").should eq "application/octet-stream"
  end

  it "only the generic XML type is refined" do
    Marcel::Magic::Xml.refine(IO::Memory.new(xml(%(<rss/>))), "application/zip").should eq "application/zip"
    Marcel::Magic::Xml.refine(IO::Memory.new(xml(%(<rss/>))), "text/html").should eq "text/html"
  end

  it "a large document is scanned within its bounded prefix" do
    io = CountingIO.new(DECLARATION + "<!--" + ("x" * 10 * 1024 * 1024) + %(--><rss/>))

    started = Time.instant
    Marcel::Magic::Xml.refine(io, "application/xml").should eq "application/xml"
    (Time.instant - started).should be < 1.second
    io.bytes_read.should eq MAX_SCAN
  end

  it "adversarial prologs give up in bounded time" do
    quotes = xml(%(<!DOCTYPE r [) + (%(") * 20_000) + %(<!--) * 5_000)
    pis = xml(%(<?a?>) * 10_000 + %(<!DOCTYPE r [) + (%(<?b ]>) * 5_000))

    started = Time.instant
    detect(quotes).should eq "application/xml"
    detect(pis).should eq "application/xml"
    (Time.instant - started).should be < 1.second
  end

  it "a filename refines generic XML content to a feed type" do
    detect(xml(%(<root/>)), name: "feed.rss").should eq "application/rss+xml"
    detect(xml(%(<root/>)), name: "feed.atom").should eq "application/atom+xml"
    detect(xml(%(<root/>)), declared_type: "application/xslt+xml").should eq "application/xslt+xml"
  end

  it "content-detected feed types are not overridden by a conflicting sibling hint" do
    detect(xml(%(<rss version="2.0"/>)), name: "feed.atom").should eq "application/rss+xml"
    detect(xml(%(<rss version="2.0"/>)), name: "feed.xml").should eq "application/rss+xml"
  end

  it "existing XML-flavoured fixtures keep their types" do
    Marcel::MimeType.for(files("magic/application/xml/xml.xml")).should eq "application/xml"
    Marcel::MimeType.for(files("magic/image/svg+xml/svg_with_comment.svg")).should eq "image/svg+xml"
    Marcel::MimeType.for(files("magic/text/html/html_with_leading_comment.html")).should eq "text/html"
  end

  it "refine leaves the IO rewound" do
    io = IO::Memory.new(xml(%(<rss version="2.0"/>)))

    Marcel::MimeType.for(io)
    io.pos.should eq 0
  end
end
