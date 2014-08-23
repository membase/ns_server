# Generate .plt file, if it doesn't exist
GET_FILENAME_COMPONENT (_couchdb_bin_dir "${COUCHDB_BIN_DIR}" REALPATH)

IF (NOT EXISTS "${COUCHBASE_PLT}")
  MESSAGE ("Generating ${COUCHBASE_PLT}...")
  EXECUTE_PROCESS (COMMAND "${CMAKE_COMMAND}" -E echo
    dialyzer --output_plt "${COUCHBASE_PLT}" --build_plt
    --apps compiler crypto erts inets kernel os_mon sasl ssl stdlib xmerl
    ${_couchdb_bin_dir}/src/mochiweb
    ${_couchdb_bin_dir}/src/snappy ${_couchdb_bin_dir}/src/etap
    # MISSING?  ${_couchdb_bin_dir}/src/ibrowse
    ${_couchdb_bin_dir}/src/lhttpc
    ${_couchdb_bin_dir}/src/erlang-oauth deps/erlwsh/ebin deps/gen_smtp/ebin)

  EXECUTE_PROCESS (COMMAND dialyzer --output_plt "${COUCHBASE_PLT}" --build_plt
    --apps compiler crypto erts inets kernel os_mon sasl ssl stdlib xmerl
    ${_couchdb_bin_dir}/src/mochiweb
    ${_couchdb_bin_dir}/src/snappy ${_couchdb_bin_dir}/src/etap
    # MISSING?  ${_couchdb_bin_dir}/src/ibrowse
    ${_couchdb_bin_dir}/src/lhttpc
    ${_couchdb_bin_dir}/src/erlang-oauth deps/erlwsh/ebin deps/gen_smtp/ebin)
ENDIF (NOT EXISTS "${COUCHBASE_PLT}")

# Compute list of .beam files
FILE (GLOB beamfiles RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" ebin/*.beam)
STRING (REGEX REPLACE "ebin/(couch_log|couch_api_wrap(_httpc)?).beam\;?" "" beamfiles "${beamfiles}")

# If you update the dialyzer command, please also update this echo
# command so it displays what is invoked. Yes, this is annoying.
EXECUTE_PROCESS (COMMAND "${CMAKE_COMMAND}" -E echo
  dialyzer --plt "${COUCHBASE_PLT}" ${DIALYZER_FLAGS}
  --apps ${beamfiles}
  deps/ale/ebin
  ${_couchdb_bin_dir}/src/couchdb ${_couchdb_bin_dir}/src/couch_set_view ${_couchdb_bin_dir}/src/couch_view_parser
  ${_couchdb_bin_dir}/src/couch_index_merger/ebin
  ${_couchdb_bin_dir}/src/mapreduce
  deps/ns_babysitter/ebin
  deps/ns_ssl_proxy/ebin
  deps/ns_couchdb/ebin)
EXECUTE_PROCESS (RESULT_VARIABLE _failure
  COMMAND dialyzer --plt "${COUCHBASE_PLT}" ${DIALYZER_FLAGS}
  --apps ${beamfiles}
  deps/ale/ebin
  ${_couchdb_bin_dir}/src/couchdb ${_couchdb_bin_dir}/src/couch_set_view ${_couchdb_bin_dir}/src/couch_view_parser
  ${_couchdb_bin_dir}/src/couch_index_merger/ebin
  ${_couchdb_bin_dir}/src/mapreduce
  deps/ns_babysitter/ebin
  deps/ns_ssl_proxy/ebin
  deps/ns_couchdb/ebin)
IF (_failure)
  MESSAGE (FATAL_ERROR "failed running dialyzer")
ENDIF (_failure)
