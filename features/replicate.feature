@later
Feature: Replication
  As a user of membase
  I want replication to work

  Scenario: Simple persistence
    Given I have configured nodes A and B
    And node B is a replication slave of node A
    And I add a replicated bucket named Foo to node A
    When I set key-value data into the Foo bucket
    And node A goes down
    Then I should get the same key-value data from the Foo bucket from node B

