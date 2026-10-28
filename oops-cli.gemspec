require_relative "lib/oops/version"

Gem::Specification.new do |spec|
  spec.name = "oops-cli"
  spec.version = Oops::VERSION
  spec.summary = "Copy the last shell command and its output to the clipboard"
  spec.authors = ["oops authors"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*"] + Dir["exe/*"]
  spec.bindir = "exe"
  spec.executables = ["oops"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
