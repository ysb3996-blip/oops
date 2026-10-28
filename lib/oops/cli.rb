require "optparse"

module Oops
  module CLI
    def self.run(argv, env: ENV, stdout: $stdout, stderr: $stderr) # rubocop:disable Lint/UnusedMethodArgument
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
  end
end
