Feature: Simple Clustering
  In order to have efficient use of resources
  As a user of northscale software
  I want to be able to join and eject nodes from a cluster

  Scenario: Join 2 nodes
    Given I have configured nodes A and B
    And they are not joined
    When I join node A to B
    Then all nodes know about each other

  Scenario: Unjoin 2 nodes
    Given I have configured nodes A and B
    And they are already joined
    When I tell node A to leave the cluster
    Then the nodes stop knowing about each other

