@later
Feature: Persistence Rebalancing Data
  As a user of membase
  I want persistence to work

  Scenario: Data rebalanced
    Given I have configured nodes A and B
    And I add a persistent bucket named Foo to node A
    And I set key-value data into the Foo bucket
    When I join node B to node A
    Then some data should be rebalanced from node A to node B
    And I should get the same key-value data from the Foo bucket

  Scenario: Data rebalanced, 3 nodes
    Given I have configured nodes A, B and C
    And I add a persistent bucket named Foo to node A
    And I set key-value data into the Foo bucket
    When I join node B to node A
    And I join node C to node B
    Then some data should be rebalanced from node A to node B
    And some data should be rebalanced from node A to node C
    And some data should be rebalanced from node B to node C
    And I should get the same key-value data from the Foo bucket

