Given 'I am on the main page' do
  @browser.navigate.to('http://localhost:8091/t/index.html')
end

When(/I switch section to (.*)/) do |section|
  @browser["switch_#{section}"].click
end

When(/I press back button/) do
  @browser.navigate.back
end

When(/I press forward button/) do
  @browser.navigate.forward
end

Then(/I should see (.*) section/) do |section|
  waitable_condition do
    page.active_section.should == section
  end
end
