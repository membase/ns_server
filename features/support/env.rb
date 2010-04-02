require 'test/unit/assertions'

World(Test::Unit::Assertions)

$started_epmd = false

$base_cache_port = ENV['BASE_CACHE_PORT'] ? ENV['BASE_CACHE_PORT'].to_i : 12000
$base_api_port = ENV['BASE_API_PORT'] ? ENV['BASE_API_PORT'].to_i : 9000

Before do
  next if $started_epmd
  system 'erl -noshell -setcookie nocookie -sname init -run init stop >/dev/null 2>&1'
  $started_epmd = true
  ENV['DONT_START_EPMD'] = '1'
end

if ENV['CUC_DEBUG']
  After do |scenario|
    if scenario.failed?
      puts "Scenario: \"#{scenario.name}\" failed. Pausing."
      STDIN.gets
    end
  end
end
