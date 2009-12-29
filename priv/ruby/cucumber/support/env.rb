gem 'activesupport'
require 'active_support'

require 'spec/expectations'
require 'selenium/webdriver'
require 'pp'


# "before all"
$browser = Selenium::WebDriver.for(:firefox)

Before do
  @browser = $browser
end

class Page
  def initialize(b)
    @b = b
  end

  def self.def_page_model_method(local_method, remote_method = nil)
    remote_method ||= ("a"+local_method.to_s).camelize[1..-1]
    class_eval <<HERE
def #{local_method}
  @b.execute_script("return TestingSupervisor.#{remote_method}()")
end
HERE
  end

  def_page_model_method(:active_section)
  def_page_model_method(:active_graph_zoom)
  def_page_model_method(:active_keys_zoom)
  def_page_model_method(:active_stats_target)
end

# "after all"
at_exit do
  # Latest version of WebDriver just hangs here on my machine
  # Lets help it to die.
  Thread.new {
    sleep 0.75
    Process::kill "KILL", 0
  }
  $browser.close
end

class MenelausWorld
  attr_reader :page

  def initialize
    @page = Page.new($browser)
  end
  def waitable_condition
    times = 5
    while true do
      times -= 1
      begin
        return yield
      rescue Exception => e
        unless times > 0
          raise e
        end
      end
      sleep 0.05
    end
    raise last_exc
  end
end

World do
  MenelausWorld.new
end
