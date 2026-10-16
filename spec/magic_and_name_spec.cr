require "./spec_helper"

# Порт test/magic_and_name_test.rb: все фикстуры, распознаваемые по имени,
# распознаются и по содержимому + имени.
describe "Marcel::MimeType magic and name detection" do
  each_content_type_fixture("name") do |file, name, content_type|
    it "correctly returns #{content_type} for #{name} given both file and name" do
      Marcel::MimeType.for(file, name: name).should eq content_type
    end
  end
end
