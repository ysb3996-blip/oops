require "optparse"

module Oops
  module CLI
    def self.run(argv, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      case argv.first
      when "record" then return record(argv.drop(1), env: env, stdin: stdin, stdout: stdout, stderr: stderr)
      when "init" then return init(argv.drop(1), stdout: stdout, stderr: stderr)
      end

      parser = OptionParser.new do |o|
        o.banner = "Usage: oops [options]"
        o.on("-v", "--version", "Print version and exit") do
          stdout.puts "oops #{VERSION}"
          return 0
        end
        o.on("-h", "--help", "Print this help and exit") do
          stdout.puts o
          return 0
        end
      end
      parser.parse(argv)
      0
    rescue OptionParser::ParseError => e
      stderr.puts "oops: #{e.message}"
      2
    end

    # `oops record [--] <shell> [args...]`
    def self.record(args, env:, stdin:, stdout:, stderr:)
      args = args.drop(1) if args.first == "--"
      Recorder.new(args, env: env, stdin: stdin, stdout: stdout, stderr: stderr).run
    end

    # `oops init zsh|bash`: prints the snippet for `eval "$(oops init zsh)"`.
    def self.init(args, stdout:, stderr:)
      supported = ShellInit::SHELLS.join(", ")
      if args.size != 1
        stderr.puts "oops: usage: oops init <shell> (supported: #{supported})"
        return 2
      end
      unless ShellInit::SHELLS.include?(args.first)
        stderr.puts "oops: unsupported shell: #{args.first} (supported: #{supported})"
        return 2
      end
      stdout.write ShellInit.snippet(args.first, bin: File.expand_path($PROGRAM_NAME))
      0
    end
  end
end
