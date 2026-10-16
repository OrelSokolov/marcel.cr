# HTML/XHTML magic, перенесённые из lib/marcel/magic/definitions.rb гема.
# HTML — /imn (без учёта регистра), XHTML — /xmn (регистрозависимый);
# шаблон сам поглощает ведущие пробелы/XML-декларации/комментарии, а окно
# 0..4096 задаёт границу поиска (значение — regexp, чтение 256 байт от
# каждого смещения внутри окна, привязка \A).

module Marcel
  class Magic
    HTML_MAGIC = [
      MagicRule.new(0..4096, Regex.new(
        "\\A(?:\\x{FEFF})?[ \\t\\r\\n\\f]*(?:<\\?xml(?:[ \\t\\r\\n\\f]+(?:[^?]|\\?(?!>))*)?\\?>[ \\t\\r\\n\\f]*)?" +
        "(?:<!--(?:[^-]|-(?!->))*-->[ \\t\\r\\n\\f]*)*(?:<!DOCTYPE[ \\t\\r\\n\\f]+html(?=[ \\t\\r\\n\\f>])|<html(?=[ \\t\\r\\n\\f>]))",
        :ignore_case)),
    ] of MagicRule

    XHTML_MAGIC = [
      MagicRule.new(0..4096, Regex.new(
        "\\A" +
        "(?:\\x{FEFF})?[ \\t\\r\\n\\f]*" +
        "(?:<\\?xml(?:[ \\t\\r\\n\\f]+(?:[^?]|\\?(?!>))*)?\\?>[ \\t\\r\\n\\f]*)?" +
        "(?:<!--(?:[^-]|-(?!->))*-->[ \\t\\r\\n\\f]*)*" +
        "(?:" +
        "<!DOCTYPE[ \\t\\r\\n\\f]+html(?:[ \\t\\r\\n\\f]+[^>]*)?>[ \\t\\r\\n\\f]*" +
        "(?:<!--(?:[^-]|-(?!->))*-->[ \\t\\r\\n\\f]*)*" +
        ")?" +
        "<html(?=[ \\t\\r\\n\\f>])" +
        "(?:" +
        "[ \\t\\r\\n\\f]+" +
        "(?!xmlns[ \\t\\r\\n\\f]*=)" +
        "[A-Za-z_:][A-Za-z0-9_.:-]*" +
        "[ \\t\\r\\n\\f]*=[ \\t\\r\\n\\f]*" +
        "(?:\"[^\"]*\"|'[^']*')" +
        ")*" +
        "[ \\t\\r\\n\\f]+xmlns[ \\t\\r\\n\\f]*=[ \\t\\r\\n\\f]*" +
        "(?:\"http://www\\.w3\\.org/1999/xhtml\"|'http://www\\.w3\\.org/1999/xhtml')",
        :extended)),
    ] of MagicRule

    {"text/html" => HTML_MAGIC, "application/xhtml+xml" => XHTML_MAGIC}.each do |type, magic|
      extensions = Marcel::TYPE_EXTS[type]?
      parents = Marcel::TYPE_PARENTS[type]?

      Marcel::Magic.remove(type)
      Marcel::Magic.add(type, extensions: extensions, parents: parents, magic: magic)
    end
  end
end
