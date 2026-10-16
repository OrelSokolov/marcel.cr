require "./spec_helper"
require "yaml"

# Кросс-проверка против эталонных ответов гема marcel 2.1.0.
# Эталон генерируется скриптом script/generate_oracle_expected.rb
# (запускается с системным Ruby и oracle-гемом из oracle/).
PROJECT_ROOT = File.expand_path("..", __DIR__)

cases = YAML.parse(File.read(File.join(__DIR__, "oracle_expected.yml"))).as_a

cases.each do |entry|
  parts = entry.as_a
  id = parts[0].as_s
  method = parts[1].as_s
  expected = parts[-1].as_s

  it "oracle: #{id}" do
    actual = case method
    when "for_path"
      Marcel::MimeType.for(Path[PROJECT_ROOT].join(parts[2].as_s))
    when "for_name"
      Marcel::MimeType.for(name: parts[2].as_s)
    when "for_ext"
      Marcel::MimeType.for(extension: parts[2].as_s)
    when "for_file_name"
      Marcel::MimeType.for(Path[PROJECT_ROOT].join(parts[2].as_s), name: parts[3].as_s)
    when "for_declared"
      declared = parts[2].as_s?
      Marcel::MimeType.for(declared_type: declared.nil? || declared.empty? ? nil : declared)
    when "for_content"
      Marcel::MimeType.for(parts[2].as_s)
    else
      raise "unknown oracle method: #{method}"
    end

    actual.should eq(expected), "oracle #{id}: expected #{expected}, got #{actual}"
  end
end
