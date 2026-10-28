require "optparse"

module Oops
  module CLI
    def self.run(argv, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      return record(argv.drop(1), env: env, stdin: stdin, stdout: stdout, stderr: stderr) if argv.first == "record"

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
  end
end
