require 'rake'
require 'rake/testtask'
require 'fileutils'
require 'pry'
require 'health-data-standards'
require 'rails'
require 'health-data-standards/railtie'

require_relative 'lib/bonnie_bundler'

# Pull in any rake task defined in lib/tasks
Dir['lib/tasks/**/*.rake'].sort.each do |ext|
  load ext
end

desc "Run basic tests"
Rake::TestTask.new(:test_unit) do |t|
  t.libs << "test"
  t.test_files = FileList['test/**/*_test.rb']
  t.verbose = true
  t.warning = false
end

task :test => [:test_unit] do
  system("open coverage/index.html")
end

task :default => [:test]
