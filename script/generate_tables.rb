#!/usr/bin/env ruby
# frozen_string_literal: true

# Генерирует src/marcel/tables.cr из oracle-гема (lib/marcel/tables.rb).
# Дамп делается по сырому (pre-definitions) состоянию таблиц; мутации из
# definitions-файлов воспроизводятся в Crystal при require, как в Ruby.
#
# Запуск из корня marcel.cr: ruby script/generate_tables.rb

TABLES_RB = File.expand_path("../oracle/marcel-2.1.0/lib/marcel/tables.rb", __dir__)
OUTPUT    = File.expand_path("../src/marcel/tables.cr", __dir__)

require TABLES_RB

def cr_string(bytes)
  out = +'"'
  bytes.each_byte do |b|
    case b
    when 0x22 then out << '\\"'
    when 0x5C then out << "\\\\"
    when 0x0A then out << "\\n"
    when 0x0D then out << "\\r"
    when 0x09 then out << "\\t"
    when 0x20..0x7E then out << b.chr
    else out << format("\\x%02X", b)
    end
  end
  out << '"'
end

def cr_value(value)
  case value
  when String then "#{cr_string(value)}.to_slice"
  when Regexp then "Regex.new(#{cr_string(value.source.b.gsub("\\u0000", "\\x00"))})"
  when Integer then value.to_s
  when Range then "#{value.begin}..#{value.end}"
  when nil then "nil"
  else raise "unhandled value class #{value.class}"
  end
end

def cr_rule(rule)
  offset, value, children = rule
  head = "MagicRule.new(#{cr_value(offset)}, #{cr_value(value)}"
  if children
    "#{head}, [#{children.map { |r| cr_rule(r) }.join(", ")}])"
  else
    "#{head})"
  end
end

File.open(OUTPUT, "w") do |f|
  f.puts "# This file is auto-generated from marcel 2.1.0 lib/marcel/tables.rb."
  f.puts "# Instead of editing this file, please regenerate: ruby script/generate_tables.rb"
  f.puts
  f.puts "module Marcel"
  f.puts "  EXTENSIONS = {"

  Marcel::EXTENSIONS.sort.each do |ext, type|
    f.puts "    #{cr_string(ext)} => #{cr_string(type)},"
  end
  f.puts "  } of String => String"

  f.puts
  f.puts "  TYPE_EXTS = {"
  Marcel::TYPE_EXTS.sort.each do |type, exts|
    f.puts "    #{cr_string(type)} => [#{exts.map { |e| cr_string(e) }.join(", ")}],"
  end
  f.puts "  } of String => Array(String)"

  f.puts
  f.puts "  TYPE_ALIASES = {"
  Marcel::TYPE_ALIASES.sort.each do |aliased, canonical|
    f.puts "    #{cr_string(aliased)} => #{cr_string(canonical)},"
  end
  f.puts "  } of String => String"

  f.puts
  f.puts "  TYPE_PARENTS = {"
  Marcel::TYPE_PARENTS.sort.each do |type, parents|
    f.puts "    #{cr_string(type)} => [#{parents.map { |p| cr_string(p) }.join(", ")}],"
  end
  f.puts "  } of String => Array(String)"

  f.puts
  f.puts "  ROOT_XML = {"
  Marcel::ROOT_XML.sort_by { |(ns, local), _| [ns.to_s, local] }.each do |(ns, local), type|
    f.puts "    { #{ns ? cr_string(ns) : "nil"}, #{cr_string(local)} } => #{cr_string(type)},"
  end
  f.puts "  } of Tuple(String?, String) => String"

  f.puts
  f.puts "  MAGIC = ["
  Marcel::MAGIC.each do |type, rules|
    f.puts "    MagicEntry.new(#{cr_string(type)}, ["
    rules.each { |rule| f.puts "      #{cr_rule(rule)}," }
    f.puts "    ]),"
  end
  f.puts "  ] of MagicEntry"

  f.puts "end"
end

puts "Wrote #{OUTPUT}"
