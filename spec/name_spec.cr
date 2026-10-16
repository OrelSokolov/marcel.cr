require "./spec_helper"

# Порт test/name_test.rb. UTF-16-имена из Ruby-теста дают строки с NUL-байтами;
# здесь оба «непарсимых» случая покрываются NUL-именем и невалидной кодировкой.
describe "Marcel::MimeType name detection" do
  it "ignores invalidly encoded filename extensions without raising" do
    invalid_name = String.new("file.html".to_slice + Bytes[0xFF])

    Marcel::Magic.by_path(invalid_name).should be_nil
    Marcel::MimeType.for(name: invalid_name).should eq "application/octet-stream"
  end

  it "uses a valid extension after an invalidly encoded basename" do
    name = String.new("file".to_slice + Bytes[0xFF] + ".html".to_slice)

    Marcel::MimeType.for(name: name).should eq "text/html"
  end

  it "ignores filenames that cannot be parsed as paths" do
    invalid_names = [
      "file.html\0.pdf",
      String.new("file.html".to_slice + Bytes[0x00, 0x66, 0x00, 0x69]),
    ]

    invalid_names.each do |invalid_name|
      Marcel::Magic.by_path(invalid_name).should be_nil
      Marcel::MimeType.for(name: invalid_name).should eq "application/octet-stream"
    end
  end

  each_content_type_fixture("name") do |_file, name, content_type|
    it "gets type for #{content_type} by filename from #{name}" do
      Marcel::MimeType.for(name: name).should eq content_type
    end
  end
end
