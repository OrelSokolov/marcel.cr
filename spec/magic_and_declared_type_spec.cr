require "./spec_helper"

# Порт test/magic_and_declared_type_test.rb.
describe "Marcel::MimeType magic and declared type detection" do
  each_content_type_fixture("name") do |file, name, content_type|
    it "correctly returns #{content_type} for #{name} given both file and declared type" do
      Marcel::MimeType.for(file, declared_type: content_type).should eq content_type
    end

    Marcel::ALIASED[content_type]?.try &.each do |aliased|
      it "correctly returns #{content_type} for #{name} given both file and aliased type #{aliased}" do
        Marcel::MimeType.for(file, declared_type: aliased).should eq content_type
      end
    end
  end
end
