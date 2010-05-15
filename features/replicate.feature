@later
Feature: Replication
  As a user of membase
  I want replication to work

  Scenario Outline: Simple master-slave, 2-node replication
    Given I have configured nodes A and B
      And node B is a replication slave of node A
      And I add a replicated bucket named Foo to node A with replica count of <replica_count>
     When I set key-value data into the Foo bucket
      And node A goes down
     Then I should get the same key-value data from the Foo bucket from node B
    Examples:
      | replica_count |
      | 1             |
      | 2             |

  Scenario Outline: Simple master-slave, 3-node chain replication
    Given I have configured nodes A, B, C
      And node B is a replication slave of node A
      And node C is a replication slave of node B
      And I add a replicated bucket named Foo to node A with replica count of 2
     When I set key-value data into the Foo bucket
      And node <down_node> goes down
     Then I should get the same key-value data from the Foo bucket from any of the <remaining_nodes>
    Examples:
      | down_node | remaining_nodes |
      | A         | B, C            |
      | B         | A, C            |
      | C         | A, B            |

