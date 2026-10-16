require "spec"
require "../src/marcel"

# Reverse mapping from canonical type to its aliases. Only needed for testing.
module Marcel
  ALIASED = begin
    hash = {} of String => Array(String)
    TYPE_ALIASES.each do |aliased, type|
      (hash[type] ||= [] of String) << aliased
    end
    hash
  end
end

def fixture_path(name : String) : String
  File.expand_path(File.join("fixtures", name), __DIR__)
end

def files(name : String) : Path
  Path[fixture_path(name)]
end

# Аналог each_content_type_fixture из Ruby test_helper: путь вида
# «тип/подтип/[extra.]ext» даёт content_type «тип/подтип».
def each_content_type_fixture(folder : String, &)
  Dir.glob(File.join(fixture_path(folder), "**", "*.*")).sort.each do |path|
    next unless File.file?(path)

    name = path[(fixture_path(folder).size + 1)..]
    if match = name.match(/\A([^\/]+\/[^\/]*)\/?(.*)\.(\w+)\Z/)
      content_type = match[1]
      extra = match[2]?
      extra = nil if extra && content_type.ends_with?(extra)
      yield files(File.join(folder, name)), name, content_type
    end
  end
end

# IO только с последовательным чтением и rewind (аналог Rack-обёрток и
# RewindableInput): не определяет ни seek, ни size.
class RewindOnlyIO < IO
  def initialize(data : String)
    @io = IO::Memory.new(data)
  end

  def read(slice : Bytes) : Int32
    @io.read(slice)
  end

  def write(slice : Bytes) : Nil
  end

  def rewind
    @io.rewind
  end
end

# IO со счётчиком read-вызовов (аналог StringIO-подкласса из Ruby-тестов).
class CountingIO < IO
  getter reads : Int32 = 0
  getter bytes_read : Int32 = 0

  def initialize(data : String)
    @io = IO::Memory.new(data)
  end

  def read(slice : Bytes) : Int32
    @reads += 1
    count = @io.read(slice)
    @bytes_read += count
    count
  end

  def write(slice : Bytes) : Nil
  end

  def rewind
    @io.rewind
  end
end
