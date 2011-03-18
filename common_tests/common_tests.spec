{logdir, "../logs"}.
{suites, "common_tests", all}.
{cover, "./common_tests.cover"}.
{skip_cases, "common_tests", config_test_SUITE, ns_config_sync, "Ignore"}.