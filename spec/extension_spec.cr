require "./spec_helper"

# Порт test/extension_test.rb.
describe "Marcel::MimeType extension detection" do
  it "ignores case and any preceding dot" do
    Marcel::MimeType.for(extension: "PDF").should eq "application/pdf"
    Marcel::MimeType.for(extension: ".PDF").should eq "application/pdf"
    Marcel::MimeType.for(extension: "pdf").should eq "application/pdf"
    Marcel::MimeType.for(extension: ".pdf").should eq "application/pdf"
  end

  it "ignores invalidly encoded extensions without raising" do
    invalid_extension = String.new("html".to_slice + Bytes[0xFF])

    Marcel::Magic.by_extension(invalid_extension).should be_nil
    Marcel::MimeType.for(extension: invalid_extension).should eq "application/octet-stream"
  end

  it "preserves valid custom non-ASCII extensions" do
    type = "application/x-unicode-extension"
    Marcel::Magic.add(type, extensions: "éx")

    Marcel::MimeType.for(extension: "ÉX").should eq type
  ensure
    Marcel::Magic.remove("application/x-unicode-extension")
  end

  extensions = [] of String

  each_content_type_fixture("name") do |_file, name, content_type|
    extension = File.extname(name)

    next if extensions.includes?(extension)

    it "gets type for #{content_type} given file extension #{extension}" do
      Marcel::MimeType.for(extension: extension).should eq content_type
    end

    extensions << extension
  end
end
