Feature: Persistence
  As a user of membase
  I want persistence to work

  Scenario: Simple persistence
    Given I have configured nodes A
    And I add a persistent bucket named Foo to node A
    When I set key-value data into the Foo bucket
    And I restart node A
    Then I should get the same key-value data from the Foo bucket

  Scenario: Simple persistence, 1 node restarted
    Given I have configured nodes A and B
    And they are already joined
    And I add a persistent bucket named Foo to node A
    When I set key-value data into the Foo bucket
    And I restart node A
    Then I should get the same key-value data from the Foo bucket

  Scenario: Simple persistence, 2 nodes restarted
    Given I have configured nodes A and B
    And they are already joined
    And I add a persistent bucket named Foo to node A
    When I set key-value data into the Foo bucket
    And I restart node A
    And I restart node B
    Then I should get the same key-value data from the Foo bucket
