module Oops
  # Turns captured records into the paste-ready clipboard text.
  #
  # Per field (command line and output) the pipeline is: strip ANSI, scrub
  # invalid UTF-8, shorten the home directory to "~", mask secrets, apply the
  # config replace table. Output is then truncated (head/tail) and fenced.
  # With show_secrets, the home/mask/replace steps are skipped.
  class Formatter
    GITHUB_COLLAPSE_LINES = 30

    # lines: output lines shown after formatting, summed over records. The
    # "... N lines omitted ..." marker is not counted.
    # command_line: the formatted first command, without "$ " or indentation.
    Result = Struct.new(:text, :lines, :masked_count, :command_line)

    def initialize(config:, home: Dir.home, show_secrets: false, head: nil, tail: nil, github: false)
      @config = config
      @home = home.to_s
      @show_secrets = show_secrets
      @head = head
      @tail = tail
      @github = github
      @masked = 0
    end

    def format(records)
      @masked = 0
      blocks = records.map { |record| build_block(record) }
      text = @github ? blocks.map { |b| github_block(b) }.join("\n") : plain_text(blocks)
      Result.new(text, blocks.sum { |b| b[:count] }, @masked, blocks.first&.dig(:command))
    end

    private

    def build_block(record)
      command = clean(record.cmd.to_s).sub(/\s+\z/, "")
      shown, count = shown_lines(clean(record.output.to_s))
      exit_code = record.exit
      exit_code = nil if exit_code.to_i.zero?
      body = ["$ #{command.gsub("\n", "\n  ").gsub(/^ +$/, '')}", *shown]
      body << "(exit #{exit_code})" if exit_code
      { command: command, exit: exit_code, count: count, content: body.join("\n") }
    end

    # Returns [lines to show, real output line count]: trailing blank lines
    # dropped, then head/tail truncation.
    def shown_lines(text)
      lines = text.split("\n", -1)
      lines.pop while lines.any? && lines.last.strip.empty?
      shown = truncate(lines)
      [shown, shown.equal?(lines) ? lines.size : shown.size - 1]
    end

    def truncate(lines)
      return lines if @head.nil? && @tail.nil?

      head = @head.to_i
      tail = @tail.to_i
      omitted = lines.size - head - tail
      return lines if omitted <= 0

      marker = "... #{omitted.to_s.reverse.scan(/\d{1,3}/).join(',').reverse} lines omitted ..."
      [*lines.first(head), marker, *(tail.zero? ? [] : lines.last(tail))]
    end

    def clean(raw)
      text = Ansi.strip(raw.dup).force_encoding(Encoding::UTF_8).scrub
      return text if @show_secrets

      text = shorten_home(text)
      text, count = Secrets.mask(text, extra: @config.secrets)
      @masked += count
      apply_replace(text)
    end

    def shorten_home(text)
      return text if @home.empty? || @home == "/"

      text.gsub(/#{Regexp.escape(@home)}(?!\w)/, "~")
    end

    def apply_replace(text)
      keys = @config.replace.keys.reject(&:empty?).sort_by { |k| -k.length }
      return text if keys.empty?

      table = @config.replace
      text.gsub(Regexp.union(keys)) { |match| table[match] }
    end

    def plain_text(blocks)
      fenced(blocks.map { |b| b[:content] }.join("\n\n"), "")
    end

    def github_block(block)
      fence = fenced(block[:content], "console")
      return fence if block[:count] <= GITHUB_COLLAPSE_LINES

      parts = []
      parts << "exit #{block[:exit]}" if block[:exit]
      parts << "#{block[:count]} lines"
      summary = escape_html("$ #{block[:command]}".gsub("\n", " "))
      "<details>\n<summary><code>#{summary}</code> — #{parts.join(', ')}</summary>\n\n#{fence}\n</details>\n"
    end

    def fenced(content, language)
      longest = content.scan(/`+/).map(&:length).max.to_i
      fence = "`" * [3, longest + 1].max
      "#{fence}#{language}\n#{content}\n#{fence}\n"
    end

    def escape_html(text)
      text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end
  end
end
