require "./spec_helper"

# Порт test/magic_test.rb. Ruby-специфика не переносится: frozen-string
# предупреждения, ObjectSpace, подклассы StringIO с переопределённым read
# (в Crystal один read(slice), байты и есть байты), подсчёт открытых Pathname.
#
# Побайтовые обёртки над IO::Memory для кейсов «не-seekable IO».
class ShortReadIO < IO
  # Первое чтение возвращает максимум 1 байт, дальше — сколько запросили.
  def initialize(data : String)
    @io = IO::Memory.new(data)
    @first_read = true
  end

  def read(slice : Bytes) : Int32
    count = @first_read && slice.size > 1 ? 1 : slice.size
    @first_read = false
    @io.read(slice[0, count])
  end

  def write(slice : Bytes) : Nil
  end

  def rewind
    @first_read = true
    @io.rewind
  end
end

class ByteAtATimeIO < IO
  def initialize(data : String)
    @io = IO::Memory.new(data)
  end

  def read(slice : Bytes) : Int32
    @io.read(slice[0, 1])
  end

  def write(slice : Bytes) : Nil
  end

  def rewind
    @io.rewind
  end
end

class SeekableNoSizeIO < IO
  # Отвечает на seek, но не на size (аналог Ruby-класса без метода size).
  def initialize(data : String)
    @io = IO::Memory.new(data)
  end

  def read(slice : Bytes) : Int32
    @io.read(slice)
  end

  def write(slice : Bytes) : Nil
  end

  def seek(offset, whence : IO::Seek = IO::Seek::Set)
    @io.seek(offset, whence)
  end

  def rewind
    @io.rewind
  end
end

class FailingReadIO < IO
  def initialize
    @io = IO::Memory.new("data")
  end

  def read(slice : Bytes) : Int32
    @io.read(slice[0, 1])
    raise IO::Error.new("read failed")
  end

  def write(slice : Bytes) : Nil
  end

  def rewind
    @io.rewind
  end

  def pos : Int32
    @io.pos
  end
end

class CleanupFailureIO < IO
  # read всегда падает; rewind падает со второго раза.
  def initialize(@original_error : Exception)
    @rewinds = 0
  end

  def read(slice : Bytes) : Int32
    raise @original_error
  end

  def write(slice : Bytes) : Nil
  end

  def rewind
    @rewinds += 1
    raise IO::Error.new("cleanup rewind failed") if @rewinds > 1
  end
end

class ThirdRewindFailureIO < IO
  # rewind падает ровно на третий вызов.
  def initialize(data : String)
    @io = IO::Memory.new(data)
    @rewinds = 0
  end

  def read(slice : Bytes) : Int32
    @io.read(slice)
  end

  def write(slice : Bytes) : Nil
  end

  def rewind
    @rewinds += 1
    raise IO::Error.new("cleanup rewind failed") if @rewinds == 3

    @io.rewind
  end
end

def extract_regexes(rules : Array(Marcel::MagicRule)) : Array(Tuple(Marcel::MagicOffset, Marcel::MagicValue))
  collected = [] of Tuple(Marcel::MagicOffset, Marcel::MagicValue)
  rules.each do |rule|
    collected << {rule.offset, rule.value} if rule.value.is_a?(Regex)
    collected.concat(extract_regexes(rule.children.not_nil!)) if rule.children
  end
  collected
end

describe "Marcel::Magic content detection" do
  # These fixtures should be recognisable given only their contents. Where a generic type
  # has more specific subclasses (such as application/zip), these subclasses cannot usually
  # be recognised by magic alone; their name is also needed to correctly identify them.
  each_content_type_fixture("magic") do |file, name, content_type|
    it "gets type for #{content_type} by using only magic bytes #{name}" do
      actual_type = Marcel::MimeType.for(file)
      actual_type.should eq(content_type), "Expected #{file} to be #{content_type}, but was #{actual_type}"
    end
  end

  # The generator probes the most common types ahead of the priority order, so detecting one
  # costs a few dozen bounded reads rather than a walk past every higher-priority matcher.
  it "common types are detected within a bounded read budget" do
    budgets = {
      "image/jpeg"      => {"magic/image/jpeg/jpeg.jpg", 48},
      "image/png"       => {"magic/image/png/png.png", 48},
      "image/gif"       => {"magic/image/gif/gif.gif", 48},
      "application/pdf" => {"magic/application/pdf/pdf.pdf", 128},
    }

    budgets.each do |type, (fixture, budget)|
      io = CountingIO.new(File.read(fixture_path(fixture)))

      Marcel::MimeType.for(io).should eq type
      io.reads.should be <= budget
    end
  end

  it "other CMS content types are not misdetected as timestamped-data" do
    compressed_data = String.new(Bytes[
      0x30, 0x80, 0x06, 0x0B, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D,
      0x01, 0x09, 0x10, 0x01, 0x09, 0xA0, 0x80,
    ])

    Marcel::MimeType.for(compressed_data).should eq "application/octet-stream"
  end

  it "add and remove type" do
    Marcel::Magic.add("application/x-my-thing", extensions: "mtg", parents: "application/json")
    Marcel::Magic.remove("application/x-my-thing")
  end

  it "switch canonical type" do
    Marcel::Magic.add("canonical/type", aliases: "alias/type", extensions: %w(canonical),
      parents: "canonical/parent", magic: [Marcel::MagicRule.new(0, "magic".to_slice)])
    Marcel::Magic.child?("canonical/type", "canonical/parent").should be_true
    Marcel::Magic.canonical("alias/type").should eq "canonical/type"
    Marcel::Magic.by_extension("canonical").not_nil!.type.should eq "canonical/type"
    Marcel::Magic.by_magic("magic").not_nil!.type.should eq "canonical/type"
    Marcel::Magic.new("canonical/type").extensions.should eq %w(canonical)

    Marcel::Magic.canonicalize("alias/type", "canonical/type")
    Marcel::Magic.child?("alias/type", "canonical/parent").should be_true
    Marcel::Magic.canonical("alias/type").should eq "alias/type"
    Marcel::Magic.canonical("canonical/type").should eq "alias/type"
    Marcel::Magic.by_extension("canonical").not_nil!.type.should eq "alias/type"
    Marcel::Magic.by_magic("magic").not_nil!.type.should eq "alias/type"
    Marcel::Magic.new("alias/type").extensions.should eq %w(canonical)
  ensure
    Marcel::Magic.remove("alias/type")
    Marcel::Magic.remove("canonical/type")
  end

  it "canonicalizing instead of an alias is an error" do
    Marcel::Magic.add("canonical/type", aliases: "alias/type")

    expect_raises(ArgumentError) do
      Marcel::Magic.canonicalize("other/type", "alias/type")
    end
  ensure
    Marcel::Magic.remove("canonical/type")
  end

  it "removing alias" do
    Marcel::Magic.add("canonical/type", aliases: "alias/type")
    Marcel::Magic.canonical("alias/type").should eq "canonical/type"

    Marcel::Magic.remove("alias/type")
    Marcel::Magic.canonical("alias/type").should eq "alias/type"
  ensure
    Marcel::Magic.remove("canonical/type")
  end

  it "removing canonical removes aliases" do
    Marcel::Magic.add("canonical/type", aliases: %w(alias/one alias/two))
    Marcel::Magic.canonical("alias/one").should eq "canonical/type"
    Marcel::Magic.canonical("alias/two").should eq "canonical/type"

    Marcel::Magic.remove("canonical/type")
    Marcel::Magic.canonical("alias/one").should eq "alias/one"
    Marcel::Magic.canonical("alias/two").should eq "alias/two"
  end

  it "adding type removes existing alias" do
    Marcel::Magic.add("canonical/type", aliases: "alias/type")
    Marcel::Magic.canonical("alias/type").should eq "canonical/type"

    Marcel::Magic.add("alias/type")
    Marcel::Magic.canonical("alias/type").should eq "alias/type"
  ensure
    Marcel::Magic.remove("alias/type")
    Marcel::Magic.remove("canonical/type")
  end

  it "aliases are normalized to lowercase" do
    Marcel::Magic.add("canonical/type", aliases: "Alias/Type")
    Marcel::Magic.canonical("alias/type").should eq "canonical/type"
    Marcel::Magic.canonical("Alias/Type").should eq "canonical/type"
  ensure
    Marcel::Magic.remove("canonical/type")
  end

  it "aliasing a registered type is an error and leaves every registry untouched" do
    Marcel::Magic.add("registered/type", extensions: "reg")
    snapshots = [Marcel::EXTENSIONS.dup, Marcel::TYPE_EXTS.dup, Marcel::TYPE_PARENTS.dup,
                 Marcel::TYPE_ALIASES.dup, Marcel::MAGIC.dup]

    expect_raises(ArgumentError) do
      Marcel::Magic.add("candidate/type", extensions: "txt", parents: "text/plain",
        magic: [Marcel::MagicRule.new(0, "candidate".to_slice)],
        aliases: %w(alias/fine registered/type))
    end

    [Marcel::EXTENSIONS, Marcel::TYPE_EXTS, Marcel::TYPE_PARENTS,
     Marcel::TYPE_ALIASES, Marcel::MAGIC].should eq snapshots
    Marcel::Magic.by_extension("txt").not_nil!.type.should eq "text/plain"
  ensure
    Marcel::Magic.remove("registered/type")
  end

  it "canonicalizing re-points existing aliases so resolution stays single-hop" do
    Marcel::Magic.add("first/type", aliases: "alias/type")
    Marcel::Magic.canonicalize("second/type", "first/type")

    Marcel::Magic.canonical("first/type").should eq "second/type"
    Marcel::Magic.canonical("alias/type").should eq "second/type"
  ensure
    Marcel::Magic.remove("second/type")
    Marcel::Magic.remove("first/type")
  end

  it "#extensions" do
    json = Marcel::Magic.by_extension("json").not_nil!
    json.extensions.should eq ["json"]
  end

  it ".child?" do
    Marcel::Magic.child?("text/csv", "text/plain").should be_true
    Marcel::Magic.child?("text/plain", "text/csv").should be_false
  end

  it ".child? with aliases" do
    Marcel::Magic.add("canonical/parent", aliases: "alias/parent")
    Marcel::Magic.add("canonical/child", aliases: "alias/child", parents: "canonical/parent")

    Marcel::Magic.child?("alias/child", "alias/parent").should be_true
  ensure
    Marcel::Magic.remove("canonical/child")
    Marcel::Magic.remove("canonical/parent")
  end

  it "X bitmap resolves its C source alias to a canonical text parent" do
    Marcel::Magic.child?("image/x-xbitmap", "text/x-csrc").should be_true
    Marcel::Magic.new("image/x-xbitmap").text?.should be_true
  end

  it ".child? handles custom parent cycles" do
    Marcel::Magic.add("application/x-cycle-a", parents: "application/x-cycle-b")
    Marcel::Magic.add("application/x-cycle-b", parents: "application/x-cycle-a")

    Marcel::Magic.child?("application/x-cycle-a", "application/zip").should be_false
  ensure
    Marcel::Magic.remove("application/x-cycle-a")
    Marcel::Magic.remove("application/x-cycle-b")
  end

  it "none of the regex patterns should match random test data" do
    ignore_list = %w(application/x-dbf)

    # 🇨🇭, невалидные байты, 🧀 cheese
    test_data = String.new(Bytes[
      0xF0, 0x9F, 0x87, 0xA8, 0xF0, 0x9F, 0x87, 0xAD, 0x20,
      0xFF, 0xFE, 0x03, 0x05, 0x06,
      0xF0, 0x9F, 0xA7, 0x80, 0x20,
      0x63, 0x68, 0x65, 0x65, 0x73, 0x65, 0x06, 0x07, 0x03,
    ])

    Marcel::MAGIC.each do |entry|
      next if ignore_list.includes?(entry.type)

      result = Marcel::Magic.magic_match_io(IO::Memory.new(test_data), entry.rules)
      result.should be_false
    end
  end

  it "nested match: parent AND child must both match" do
    test_rules = [Marcel::MagicRule.new(0, "AAA".to_slice, [Marcel::MagicRule.new(3, "BBB".to_slice)])]

    Marcel::Magic.magic_match_io(IO::Memory.new("AAABBB"), test_rules).should be_true
    Marcel::Magic.magic_match_io(IO::Memory.new("AAAXXX"), test_rules).should be_false
  end

  it "sibling matches use OR logic" do
    test_rules = [
      Marcel::MagicRule.new(0, "XXX".to_slice),
      Marcel::MagicRule.new(0, "YYY".to_slice),
    ]

    Marcel::Magic.magic_match_io(IO::Memory.new("XXX"), test_rules).should be_true
    Marcel::Magic.magic_match_io(IO::Memory.new("YYY"), test_rules).should be_true
    Marcel::Magic.magic_match_io(IO::Memory.new("ZZZ"), test_rules).should be_false
  end

  it "parent with multiple child alternatives (OR)" do
    test_rules = [
      Marcel::MagicRule.new(0, "ROOT".to_slice, [
        Marcel::MagicRule.new(4, "OPT1".to_slice),
        Marcel::MagicRule.new(4, "OPT2".to_slice),
      ]),
    ]

    Marcel::Magic.magic_match_io(IO::Memory.new("ROOTOPT1"), test_rules).should be_true
    Marcel::Magic.magic_match_io(IO::Memory.new("ROOTOPT2"), test_rules).should be_true
    Marcel::Magic.magic_match_io(IO::Memory.new("ROOTXXXX"), test_rules).should be_false
  end

  it "negative offsets do not scan from the start of short data" do
    rules = [Marcel::MagicRule.new(-64, Regex.new("\\A<html>"))]

    Marcel::Magic.magic_match_io(IO::Memory.new("<html>"), rules).should be_false
  end

  it "negative offsets are skipped when the IO has no size" do
    io = SeekableNoSizeIO.new("x" * 64 + "</html>")

    rules = [Marcel::MagicRule.new(-64, Regex.new("</html>\\z"))]

    Marcel::Magic.magic_match_io(io, rules).should be_false
  end

  it "non-seekable IO consumes exact offsets despite short reads" do
    io = ShortReadIO.new("Xftypavif")

    Marcel::MimeType.for(io).should eq "application/octet-stream"
  end

  it "custom IO samples are matched as binary data" do
    # В Ruby два класса (одно- и двухаргументный read); в Crystal один
    # read(slice), байтовая семантика одинакова.
    Marcel::MimeType.for(RewindOnlyIO.new("<html><body>café</body></html>")).should eq "text/html"
    Marcel::MimeType.for(RewindOnlyIO.new(File.read(fixture_path("magic/image/png/png.png")))).should eq "image/png"
  end

  it "non-seekable IO skips offset rules at early EOF" do
    io = ByteAtATimeIO.new("Xft")

    rules = [Marcel::MagicRule.new(4, "ftypavif".to_slice)]

    Marcel::Magic.magic_match_io(io, rules).should be_false
  end

  it "public magic matching rewinds after a read exception" do
    io = FailingReadIO.new

    expect_raises(IO::Error) { Marcel::Magic.by_magic(io) }
    io.pos.should eq 0
  end

  it "a cleanup rewind failure does not mask a read failure" do
    original_error = ArgumentError.new("original read failed")
    io = CleanupFailureIO.new(original_error)

    raised = expect_raises(ArgumentError) { Marcel::Magic.by_magic(io) }
    raised.message.should eq "original read failed"
  end

  it "a cleanup rewind failure is preserved after successful matching" do
    Marcel::Magic.add("application/x-cleanup-test", magic: [Marcel::MagicRule.new(0, "MATCH".to_slice)])
    io = ThirdRewindFailureIO.new("MATCH")

    expect_raises(IO::Error, "cleanup rewind failed") { Marcel::Magic.by_magic(io) }
  ensure
    Marcel::Magic.remove("application/x-cleanup-test")
  end

  it "public magic matching accepts Paths" do
    path = files("image.gif")

    Marcel::Magic.by_magic(path).not_nil!.type.should eq "image/gif"
    Marcel::Magic.all_by_magic(path).map(&.type).should contain "image/gif"
  end

  it "complex nested structure with multiple levels" do
    # Parent AND (Child AND Grandchild)
    test_rules = [
      Marcel::MagicRule.new(0, "AAA".to_slice, [
        Marcel::MagicRule.new(3, "BBB".to_slice, [
          Marcel::MagicRule.new(6, "CCC".to_slice),
        ]),
      ]),
    ]

    Marcel::Magic.magic_match_io(IO::Memory.new("AAABBBCCC"), test_rules).should be_true
    Marcel::Magic.magic_match_io(IO::Memory.new("AAABBBXXX"), test_rules).should be_false
  end
end
