Feature: Accurate Cache Usage Stats
  As a user of northscale software
  I want accurate cache usage statistics

  Scenario: Fill bucket
    Given I have configured nodes A
    And default bucket has size 128M
    When I put 64M of data to default bucket
    Then I should get 50% cache utilization for default bucket
