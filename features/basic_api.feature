Feature: Basic API
  As a user of northscale software
  I want meaningfull behavior of REST API

  Scenario: Requesting unknown bucket details
    Given I have configured node A
    When I GET path /pools/default/buckets/nonexistant on node A
    Then I should get status code 404

  Scenario: Requesting known bucket details
    Given I have configured node A
    When I GET path /pools/default/buckets/default on node A
    Then I should get status code 200
    And I should get parsable json
