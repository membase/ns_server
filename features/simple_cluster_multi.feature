Feature: Simple Clustering With > 2 Nodes
  In order to have efficient use of resources
  As a user of membase software
  I want to be able to join and eject nodes from a cluster

  Scenario Outline: Join 3 nodes, A, B, C
    Given I have configured nodes A, B and C
    And they are not joined
    When I join node <joiner1> to <joinee1>
    And I join node <joiner2> to <joinee2>
    Then all nodes know about each other

    Examples:
      | joiner1 | joinee1 | joiner2 | joinee2 |
      | A       | B       | C       | B       |
      | A       | B       | C       | A       |

  Scenario: Eject 1 out of 3 nodes
    Given I have configured nodes A, B, C
    And they are already joined
    When I tell node A to leave the cluster
    Then node B and C know about each other
    And node A and B don't know about each other
    And node A and C don't know about each other

