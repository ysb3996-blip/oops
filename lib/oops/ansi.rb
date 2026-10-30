module Oops
  # Removes terminal control sequences from captured output. Binary-safe:
  # never raises on invalid UTF-8 and never scrubs; the result keeps the
  # input's encoding.
  module Ansi
    ESCAPES = Regexp.new(
      [
        "\\e\\[[0-?]*[ -/]*[@-~]",              # CSI
        "\\e\\][^\\a\\e]*(?:\\a|\\e\\\\|\\z)",  # OSC
        "\\e[P_^X][^\\e]*(?:\\e\\\\)?",         # DCS, APC, PM, SOS (unterminated: up to the next ESC)
        "\\e[ -/]+[0-~]",                       # nF sequences
        "\\e[@-~]?",                            # 2-char ESC sequences
        "\\a"                                   # BEL
      ].join("|"),
      Regexp::MULTILINE | Regexp::NOENCODING
    )

    module_function

    def strip(bytes)
      encoding = bytes.encoding
      text = bytes.b.gsub(ESCAPES, "".b).gsub("\r\n".b, "\n".b)
      lines = text.split("\n".b, -1).map { |line| apply_line_controls(line, encoding) }
      lines.join("\n".b).force_encoding(encoding)
    end

    def apply_line_controls(line, encoding)
      line = line.split("\r".b).reverse.find { |part| !part.empty? } || "".b if line.include?("\r".b)
      return line unless line.include?("\b".b)

      units = line.dup.force_encoding(encoding)
      units = units.valid_encoding? ? units.chars : line.chars
      out = []
      units.each { |u| u.b == "\b".b ? out.pop : out << u }
      out.map(&:b).join
    end
  end
end
