require "./spec_helper"

# Порт test/illustrator_test.rb.
describe "Marcel::MimeType Illustrator detection" do
  file = files("name/application/illustrator/illustrator.ai")

  it ".ai uploaded as application/postscript" do
    Marcel::MimeType.for(file, name: "illustrator.ai", declared_type: "application/postscript").should eq "application/illustrator"
  end

  it ".ai uploaded as application/pdf" do
    Marcel::MimeType.for(file, name: "illustrator.ai", declared_type: "application/pdf").should eq "application/illustrator"
  end

  it ".ai uploaded as binary" do
    Marcel::MimeType.for(file, name: "illustrator.ai", declared_type: "application/octet-stream").should eq "application/illustrator"
  end
end
