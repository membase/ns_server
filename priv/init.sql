-- Initialization parameters for sqlite backend for membase buckets.
pragma auto_vacuum = none;
pragma journal_mode = WAL;
pragma read_uncommitted = true;
