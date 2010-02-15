Feature: Basic navigation
  As a user
  I want to switch major app sections
  And I want working back/forward button and bookmarks

  Scenario: Main page is overview section
    Given I am on the main page
    Then I should see overview section

  Scenario: Switching to alerts and back works
    Given I am on the main page
    When I switch section to alerts
    Then I should see alerts section
    And when I press back button
    Then I should see overview section
    And when I press forward button
    Then I should see alerts section
