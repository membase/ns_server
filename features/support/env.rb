require 'test/unit/assertions'

World(Test::Unit::Assertions)

if ENV['CUC_DEBUG']
  After do |scenario|
    if scenario.failed?
      puts "Scenario: \"#{scenario.name}\" failed. Pausing."
      STDIN.gets
    end
  end
end
