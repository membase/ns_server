Feature: Node Removal
  In order to have efficient use of resources
  As a user of membase software
  I want to be able to remove nodes from a cluster

  Scenario: Remove self from cluster
    Given I have configured nodes A and B
    And they are already joined
    When I ask node A to remove node A from the cluster
    Then node A and B don't know about each other

  Scenario: Remove another node from cluster
    Given I have configured nodes A and B
    And they are already joined
    When I ask node A to remove node B from the cluster
    Then node A and B don't know about each other

  Scenario: Remove self from 3-node cluster
    Given I have configured nodes A, B and C
    And they are already joined
    When I ask node A to remove node A from the cluster
    Then node B and C know about each other
    And node A and B don't know about each other
    And node A and C don't know about each other

  Scenario: Remove other node from 3-node cluster
    Given I have configured nodes A, B and C
    And they are already joined
    When I ask node B to remove node A from the cluster
    Then node B and C know about each other
    And node A and B don't know about each other
    And node A and C don't know about each other

