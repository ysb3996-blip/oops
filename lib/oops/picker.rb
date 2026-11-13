module Oops
  # The numbered list that `oops pick` shows, and what the user types back.
  # Numbers run from 1 (oldest) so the newest command sits next to the prompt.
  module Picker
    class Invalid < StandardError; end

    # Default number of commands listed.
    COUNT = 10
    # Long commands are cut so each entry stays on one terminal line.
    COMMAND_WIDTH = 60

    module_function

    # One line per record. formatter cleans and masks the command line the
    # same way the copied text is, so a token never shows up in the list.
    def menu(records, formatter)
      digits = records.size.to_s.size
      rows = records.map do |record|
        result = formatter.format([record])
        [short(result.command_line), details(record, result.lines)]
      end
      width = rows.map { |command, _| command.size }.max
      rows.each_with_index.map do |(command, details), i|
        "#{(i + 1).to_s.rjust(digits)}  $ #{command.ljust(width)}  (#{details})"
      end
    end

    # Numbers, ranges (2-4) or both, separated by spaces or commas. Returns
    # the chosen positions (1-based), sorted and without repeats, so the copy
    # keeps the order the commands ran in. Raises Invalid otherwise.
    def parse(input, size)
      tokens = input.to_s.split(/[\s,]+/).reject(&:empty?)
      raise Invalid, "nothing picked." if tokens.empty?

      tokens.flat_map { |token| positions(token, size) }.uniq.sort
    end

    def positions(token, size)
      first, last = token.match(/\A(\d+)(?:-(\d+))?\z/)&.captures
      raise Invalid, "not a number: #{token}" unless first

      range = first.to_i..(last || first).to_i
      bad = [range.begin, range.end].find { |n| n < 1 || n > size }
      raise Invalid, "no command numbered #{bad} (1-#{size})" if bad
      raise Invalid, "backwards range: #{token}" if range.none?

      range.to_a
    end

    def short(command)
      first, rest = command.to_s.split("\n", 2)
      first = first.to_s
      first = "#{first[0, COMMAND_WIDTH - 3]}..." if first.size > COMMAND_WIDTH
      rest ? "#{first} ..." : first
    end

    def details(record, lines)
      parts = ["exit #{record.exit}", "#{lines} #{lines == 1 ? 'line' : 'lines'}"]
      parts << Time.at(record.started_at.to_i).strftime("%H:%M") if record.started_at
      parts.join(", ")
    end

    private_class_method :positions, :short, :details
  end
end
