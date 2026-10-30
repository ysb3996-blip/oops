require "rake/testtask"
require "rubocop/rake_task"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/**/*_test.rb"
end

RuboCop::RakeTask.new(:rubocop)

# `rake` runs what CI runs (the gem build aside).
task default: %i[test rubocop]
