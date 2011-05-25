var ViewHelpersTest = TestCase("ViewHelpersTest");


ViewHelpersTest.prototype.testStripPort = function () {
  var servers = [
    {hostname: "lh:9000"},
    {hostname: "lh:9001"},
    {hostname: "dn2:8091"}
  ];

  var hostnames = ("lh:9000 lh:9001 dn2:8091").split(" ");

  // this tests main logic
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, servers));
  assertEquals("lh:9001", ViewHelpers.maybeStripPort(servers[1].hostname, servers));
  assertEquals("dn2:8091", ViewHelpers.maybeStripPort(servers[2].hostname, servers));

  // and this tests correctness of caching
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, servers));
  assertEquals("lh:9001", ViewHelpers.maybeStripPort(servers[1].hostname, servers));
  assertEquals("dn2:8091", ViewHelpers.maybeStripPort(servers[2].hostname, servers));

  // and main logic again
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, hostnames));
  assertEquals("lh:9001", ViewHelpers.maybeStripPort(servers[1].hostname, hostnames));
  assertEquals("dn2:8091", ViewHelpers.maybeStripPort(servers[2].hostname, hostnames));

  assertEquals("dn2", ViewHelpers.maybeStripPort("dn2", ("dn2 dn3").split(" ")));
  assertEquals("dn2", ViewHelpers.maybeStripPort("dn2:8091", ("dn2:8091 dn3:8091").split(" ")));

  // and this tests correctness of caching
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, []));
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, [servers[0]]));
  assertEquals("dn2:8091", ViewHelpers.maybeStripPort(servers[2].hostname, servers));
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, servers));
}
