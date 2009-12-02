Feature: Rebalancing
  In order to have efficient use of resources
  As a user of northscale data persistence product
  I want to data to be rebalanced correctly during pool changes

  Scenario: Add 2nd node
    Given there is a pool P
    And pool P has node A hashed at point 20
    When new node X starts joining P at point 30
    Then node X should request snapshot for arc 20 to 30 from node A
    And no other request for arc snapshots should happen

  Scenario: Add 2nd node before the 1st in the ring
    Given there is a pool P
    And pool P has node A hashed at point 20
    When new node X starts joining P at point 10
    Then node X should request snapshot for arc 20 to 10 from node A
    And no other request for arc snapshots should happen

  Scenario: Add a node between others
    Given there is a pool P
    And pool P has node A hashed at point 20
    And pool P has node B hashed at point 40
    When new node X starts joining P at point 30
    Then node X should request snapshot for arc 20 to 30 from node B
    And no other request for arc snapshots should happen

  Scenario: After receiving an arc snapshot
    Given there is a pool P
    And pool P has node A hashed at point 20
    And new node X starts joining pool P at point 30
    And node X requests arc snapshot for 20 to 30 from node A
    And update deltas still happen to arc 20 to 30 on node A
    When X has received and processed the snapshot for arc 20 to 30 from node A
    Then node X should send an arc 20 to 30 takeover message to node A
    And node A sends any update deltas for arc 20 to 30 to node X
    And node A should proxy any requests into arc 20 to 30 to node X

# adding new nodes while arcs are being requested
# adding new nodes while arcs are being taken over
