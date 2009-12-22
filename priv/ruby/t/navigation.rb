require File.dirname(__FILE__) + '/../test-lib.rb'

class NavigationTest < TestCase
  def test_opens_index
    @b.goto('http://localhost:8080/')
    location = @b.js_eval('document.location')
    assert_equal "http://localhost:8080/index.html", location
  end

  def visible?(e)
    e.visible? rescue false
  end

  def not_visible?(e)
    !visible?(e)
  end

  def test_alerts_navigation
    index_loc!

    e = @b.link(:text, 'Current Alerts')
    assert not_visible?(e)

    switch_alerts.click

    assert visible?(@b.link(:text, 'Current Alerts'))

    @b.back

    assert not_visible?(@b.link(:text, 'Current Alerts'))
  end
end
