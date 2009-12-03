Feature: Rebalance Data
  In order to have efficient use of resources
  As a user of northscale data persistence product
  I want to my data to be rebalanced correctly during pool changes

  Scenario Outline: Add 2nd node
    Given a pool P with 1 hashpoint per node, and replication num 1
    And P has node A at hashpoint <a>
    When new node X starts joining P at hashpoint <x>
    Then X should request a snapshot for arc <arc> from A
    And no other request for arc snapshots should happen
    Examples:
      | a  | x  | arc     | comment  |
      | 20 | 30 | (20,30] | after-A  |
      | 20 | 10 | (20,10] | before-A |
      |  0 | 10 |  (0,10] | A-at-0   |
      | 20 |  0 | (20,0]  | X-at-0   |

  Scenario Outline: Add a node between 2 others
    Given a pool P with 1 hashpoint per node, and replication num 1
    And P has node A at hashpoint <a>
    And P has node B at hashpoint <b>
    When new node X starts joining P at hashpoint <x>
    Then X should request a snapshot for arc <arc> from <arc_src>
    And no other request for arc snapshots should happen
    Examples:
      | a  | b  | x  | arc     | arc_src |
      | 20 | 40 | 30 | (20,30] | B       |
      | 20 | 40 | 10 | (40,10] | A       |
      | 20 | 40 | 50 | (40,50] | A       |

  Scenario: After receiving an arc snapshot, with no other traffic
    Given a pool P with 1 hashpoint per node, and replication num 1
    And P has node A at hashpoint 20
    And new node X starts joining P at hashpoint 30
    And X requests a snapshot for arc (20,30] from A
    When X has received and processed the snapshot for (20,30] from A
    Then X should send an (20,30] takeover message to A
    And A should proxy any requests for (20,30] to X
    And A should respond to the (20,30] takeover request

  Scenario: After receiving an arc snapshot, with concurrent traffic
    Given a pool P with 1 hashpoint per node, and replication num 1
    And P has node A at hashpoint 20
    And new node X starts joining P at hashpoint 30
    And X requests a snapshot for arc (20,30] from A
    And update commands still happen on (20,30] on A
    And X starts receiving the snapshot for (20,30] from A
    When X starts has finished processing the snapshot for (20,30] from A
    Then X should send an (20,30] takeover message to A
    And A should send any interim update deltas for (20,30] to X
    And A should proxy any requests for (20,30] to X
    And A should reply with success to the (20,30] takeover request

# adding new nodes while arcs are being requested
# adding new nodes while arcs are being taken over
# flapping nodes
# nodes taking forever during a step
# nodes dying during a step
# stampede after power failure and restart
## need backoff?
# explicit node removal versus node dying or going through a reboot
# crappy network that's fast between some nodes and slow between others (not-same-rack)
# cutting arcs into smaller transfer parts?
