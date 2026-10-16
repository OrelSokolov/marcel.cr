#!/usr/bin/env ruby
# frozen_string_literal: true

# Генерирует spec/oracle_expected.yml — эталонные ответы гема marcel 2.1.0
# для кросс-проверки Crystal-порта (spec/oracle_cross_check_spec.cr).
#
# Запуск из корня marcel.cr: ruby script/generate_oracle_expected.rb

require "yaml"
require "pathname"

LIB = File.expand_path("../oracle/marcel-2.1.0/lib", __dir__)
$LOAD_PATH.unshift(LIB)
require "marcel_cr"

FIXTURES = File.expand_path("../spec/fixtures", __dir__)
ROOT = File.expand_path("..", __dir__)

cases = []

# 1) Фикстуры magic/: тип только по содержимому.
Dir.glob("#{FIXTURES}/magic/**/*.*").sort.each do |path|
  next unless File.file?(path)

  name = path.sub("#{FIXTURES}/magic/", "")
  rel = path.sub("#{ROOT}/", "")
  cases << ["magic/#{name}:for_path", "for_path", rel,
            Marcel::MimeType.for(Pathname.new(path))]
end

# 2) Фикстуры name/: по имени, по расширению, по файлу и по файлу+имени.
Dir.glob("#{FIXTURES}/name/**/*.*").sort.each do |path|
  next unless File.file?(path)

  name = path.sub("#{FIXTURES}/name/", "")
  rel = path.sub("#{ROOT}/", "")
  ext = File.extname(name)

  cases << ["name/#{name}:for_path", "for_path", rel,
            Marcel::MimeType.for(Pathname.new(path))]
  cases << ["name/#{name}:for_name", "for_name", name,
            Marcel::MimeType.for(name: name)]
  unless ext.empty?
    cases << ["name/#{name}:for_ext", "for_ext", ext,
              Marcel::MimeType.for(extension: ext)]
  end
  cases << ["name/#{name}:for_file_name", "for_file_name", rel, name,
            Marcel::MimeType.for(Pathname.new(path), name: name)]
end

# 3) Declared type: разбор параметров, алиасы, регистр, мусор.
declared_types = [
  nil, "", "unrecognised", "text/html", "text/html; charset=utf-8",
  " \tTEXT/HTML\r\n", "image/jpeg;", "text/html; charset=utf-8; ",
  "application/yaml", "text/x-yaml", "text/yaml", "audio/x-aac",
  "application/javascript", "application/x-debian-package",
  "application/x-xliff+xml", "application/oxps",
  "APPLICATION/VND.EXAMPLE+JSON", %(text/html; example="one,two"),
  %(text/html; example="one\",two"), "/html", "text/", "text/ html",
  "text/html garbage", "text/html/extra", "text/{html", "tëxt/html",
  "\vtext/html", "\ftext/html", "text/html;;charset=utf-8",
  "text/html; ; charset=utf-8", %(text/html; example=foo", image/png"),
  %(text/html; example="unterminated), "text/html, image/png",
  " \tAPPLICATION/OCTET-STREAM ; example=value\r\n",
  "APPLICATION/X-EVIL", "application/" + ("a" * 9000),
]
declared_types.each do |declared|
  id = "declared:#{declared.to_s.bytesize}:#{declared.to_s.hash.abs}"
  cases << [id, "for_declared", declared,
            Marcel::MimeType.for(declared_type: declared)]
end

# 4) XML-сниффинг: содержимое (ASCII-документы, чтобы YAML остался текстовым).
DECL = %(<?xml version="1.0" encoding="UTF-8"?>)
xml_documents = {
  "rss" => %(#{DECL}\n<rss version="2.0"><channel/></rss>),
  "atom-modern" => %(#{DECL}\n<feed xmlns="http://www.w3.org/2005/Atom"/>),
  "atom-legacy" => %(#{DECL}\n<feed xmlns="http://purl.org/atom/ns#" version="0.3"/>),
  "kml-bare" => %(#{DECL}\n<kml><Placemark/></kml>),
  "kml-prefixed" => %(#{DECL}\n<k:kml xmlns:k="http://www.opengis.net/kml/2.2"/>),
  "xhtml-prefixed" => %(#{DECL}\n<h:html xmlns:h="http://www.w3.org/1999/xhtml"/>),
  "xslt" => %(#{DECL}\n<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform"/>),
  "onix-namespaced" => %(#{DECL}\n<ONIXMessage xmlns="http://ns.editeur.org/onix/3.0/reference"/>),
  "iwork-pages" => %(#{DECL}\n<sl:document xmlns:sl="http://developer.apple.com/namespaces/sl"/>),
  "office-wordml" => %(#{DECL}\n<?mso-application progid="Word.Document"?>\n<w:wordDocument xmlns:w="http://schemas.microsoft.com/office/word/2003/wordml"/>),
  "office-spreadsheetml" => %(#{DECL}\n<?mso-application progid="Excel.Sheet"?>\n<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet"/>),
  "xliff" => %(#{DECL}\n<xliff xmlns="urn:oasis:names:tc:xliff:document:1.2" version="1.2"/>),
  "html-fragment-body" => %(#{DECL}\n<body>x</body>),
  "html-fragment-script" => %(#{DECL}\n<script>x</script>),
  "unknown-root" => %(#{DECL}\n<manifest xmlns="urn:example:manifest"/>),
  "not-rss-namespace" => %(#{DECL}\n<rss xmlns="urn:example:not-rss" version="2.0"/>),
  "leading-comment" => %(<!-- generated -->\n<rss version="2.0"/>),
  "declaration-only" => DECL,
  "garbage-after-decl" => %(#{DECL}\n<rss version="2.0"/> garbage),
  "unterminated-comment" => %(#{DECL}\n<!-- unterminated <rss/>),
  "doctype-internal-subset" => %(#{DECL}\n<!DOCTYPE rss [<!ENTITY brand "<b>Acme</b>"><!-- x > -->]>\n<rss version="2.0"/>),
  "attr-angle-bracket" => %(#{DECL}\n<rss version="2.0" note="a > b"/>),
  "empty-xmlns" => %(#{DECL}\n<rss xmlns="" version="2.0"/>),
  "dup-attrs" => %(#{DECL}\n<rss xmlns="urn:x" xmlns="urn:y"/>),
  "unbound-prefix-attr" => %(#{DECL}\n<rss p:x="1"/>),
  "reserved-xmlns-binding" => %(#{DECL}\n<rss xmlns:a="http://www.w3.org/XML/1998/namespace"/>),
  "malformed-ref" => %(#{DECL}\n<rss note="a&b"/>),
  "valid-refs" => %(#{DECL}\n<rss note="a&amp;b &#65;&#x41;"/>),
  "version-1.1-ok" => %(<?xml version="1.1"?><rss/>),
  "version-1.9-rejected" => %(<?xml version="1.9"?><rss/>),
  "decl-garbage" => %(<?xml version="1.0" garbage?><rss/>),
  "plain-html" => "<html><body>hello</body>",
  "html-with-comment" => %(<!-- leading comment -->\n<html><body><svg><script></script></svg>),
  "xhtml-doctype" => %(<!DOCTYPE html><!-- c --><html xmlns="http://www.w3.org/1999/xhtml"></html>),
  "svg-comment" => %(<!-- c -->\n<svg xmlns="http://www.w3.org/2000/svg"></svg>),
}
xml_documents.each do |id, doc|
  cases << ["xml/#{id}", "for_content", doc, Marcel::MimeType.for(doc)]
end

output = File.expand_path("../spec/oracle_expected.yml", __dir__)
File.write(output, YAML.dump(cases))
puts "Wrote #{cases.size} cases to #{output}"
