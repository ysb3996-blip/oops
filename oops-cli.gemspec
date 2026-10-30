require_relative "lib/oops/version"

Gem::Specification.new do |spec|
  spec.name = "oops-cli"
  spec.version = Oops::VERSION
  spec.summary = "Copy the last shell command and its output to the clipboard"
  spec.description = "oops records what your zsh or bash prints and copies the last command (or the last " \
                     "failed one) with its output to the clipboard as a code block, with secrets masked, " \
                     "ready to paste into chat, Slack or GitHub."
  spec.authors = ["ysb3996-blip"]
  spec.email = ["ysb3996@gmail.com"]
  spec.homepage = "https://github.com/ysb3996-blip/oops"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"
  spec.files = Dir.chdir(__dir__) do
    (Dir["lib/**/*"] + Dir["exe/*"]).select { |f| File.file?(f) } + %w[README.md README.ja.md LICENSE CHANGELOG.md CHANGELOG.ja.md]
  end
  spec.bindir = "exe"
  spec.executables = ["oops"]
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"
end
