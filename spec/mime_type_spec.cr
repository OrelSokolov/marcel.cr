require "./spec_helper"

# Порт test/mime_type_test.rb. Ruby-специфика (Pathname#open binary mode,
# ObjectSpace, Rack::RewindableInput, внешние кодировки StringIO) не переносится.
describe Marcel::MimeType do
  path = files("image.gif").to_s

  it "gets content type from Files" do
    content_type = File.open(path) do |file|
      Marcel::MimeType.for file
    end
    content_type.should eq "image/gif"
  end

  it "gets content type from Paths" do
    Marcel::MimeType.for(Path[path]).should eq "image/gif"
  end

  it "gets content type from temp files" do
    tempfile = File.tempfile("marcel")
    begin
      File.write(tempfile.path, File.read(path))
      tempfile.flush
      Marcel::MimeType.for(tempfile).should eq "image/gif"
    ensure
      tempfile.delete
    end
  end

  it "gets content type from IOs" do
    Marcel::MimeType.for(IO::Memory.new(File.read(path))).should eq "image/gif"
  end

  it "gets content type from Strings treated as content" do
    Marcel::MimeType.for(File.read(path)).should eq "image/gif"
  end

  it "reads IOs from the beginning" do
    io = IO::Memory.new(File.read(path))
    io.skip(10)

    Marcel::MimeType.for(io).should eq "image/gif"
  end

  # Ruby-тест также проверяет предупреждение «is an alias» в stderr.
  it "extending a mixed-case alias redirects to the canonical type" do
    Marcel::MimeType.extend "Application/Javascript", extensions: %w(extendtestjs)

    Marcel::MimeType.for(extension: "extendtestjs").should eq "text/javascript"
    Marcel::TYPE_EXTS.has_key?("Application/Javascript").should be_false
    Marcel::TYPE_EXTS.has_key?("application/javascript").should be_false
  ensure
    Marcel::EXTENSIONS.delete("extendtestjs")
    Marcel::TYPE_EXTS["text/javascript"]?.try &.delete("extendtestjs")
  end
end
