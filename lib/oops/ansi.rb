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
        "\\e[0-~]?",                            # 2-char ESC sequences, e.g. ESC 7, ESC 8, ESC =, ESC M
        "\\a"                                   # BEL
      ].join("|"),
      Regexp::MULTILINE | Regexp::NOENCODING
    )

    # "Move the cursor right N columns": full-screen UIs use it instead of
    # printing spaces, so dropping it would glue words together.
    CURSOR_FORWARD = /\e\[(\d*)C/n
    MAX_FORWARD = 200

    # "Move to column N": the same UIs place each word this way. Columns are
    # not replayed; a jump that follows text becomes one space, so words stay
    # apart. A NUL marks the jump while the other sequences are removed.
    COLUMN_JUMP = /\e\[\d*G/n
    JUMP_MARK = "\0".b
    AFTER_TEXT_JUMP = /(?<=[^\s\0])\0+/n

    module_function

    def strip(bytes)
      encoding = bytes.encoding
      text = bytes.b.gsub(CURSOR_FORWARD) { " ".b * Regexp.last_match(1).to_i.clamp(1, MAX_FORWARD) }
      text = text.gsub(COLUMN_JUMP, JUMP_MARK).gsub(ESCAPES, "".b)
      text = text.gsub(AFTER_TEXT_JUMP, " ".b).delete(JUMP_MARK).gsub("\r\n".b, "\n".b)
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
