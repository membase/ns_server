# Generate .plt file, if it doesn't exist
GET_FILENAME_COMPONENT (_real_couchdb_src "${COUCHDB_SRC}" REALPATH)

IF (NOT EXISTS "${COUCHBASE_PLT}")
  MESSAGE ("Generating ${COUCHBASE_PLT}...")
  EXECUTE_PROCESS (COMMAND "${CMAKE_COMMAND}" -E echo
    dialyzer --output_plt "${COUCHBASE_PLT}" --build_plt
    --apps compiler crypto erts inets kernel os_mon sasl ssl stdlib xmerl
    ${COUCHDB_SRC}/src/mochiweb
    ${COUCHDB_SRC}/src/snappy ${COUCHDB_SRC}/src/etap
    # MISSING?  ${_real_couchdb_src}/src/ibrowse
    ${_real_couchdb_src}/src/lhttpc
    ${COUCHDB_SRC}/src/erlang-oauth deps/erlwsh/ebin deps/gen_smtp/ebin)

  EXECUTE_PROCESS (COMMAND dialyzer --output_plt "${COUCHBASE_PLT}" --build_plt
    --apps compiler crypto erts inets kernel os_mon sasl ssl stdlib xmerl
    ${COUCHDB_SRC}/src/mochiweb
    ${COUCHDB_SRC}/src/snappy ${COUCHDB_SRC}/src/etap
    # MISSING?  ${_real_couchdb_src}/src/ibrowse
    ${_real_couchdb_src}/src/lhttpc
    ${COUCHDB_SRC}/src/erlang-oauth deps/erlwsh/ebin deps/gen_smtp/ebin)
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
  ${COUCHDB_SRC}/src/couchdb ${COUCHDB_SRC}/src/couch_set_view ${COUCHDB_SRC}/src/couch_view_parser
  ${COUCHDB_SRC}/src/couch_index_merger/ebin
  ${_real_couchdb_src}/src/mapreduce
  deps/ns_babysitter/ebin
  deps/ns_ssl_proxy/ebin)
EXECUTE_PROCESS (RESULT_VARIABLE _failure
  COMMAND dialyzer --plt "${COUCHBASE_PLT}" ${DIALYZER_FLAGS}
  --apps ${beamfiles}
  deps/ale/ebin
  ${COUCHDB_SRC}/src/couchdb ${COUCHDB_SRC}/src/couch_set_view ${COUCHDB_SRC}/src/couch_view_parser
  ${COUCHDB_SRC}/src/couch_index_merger/ebin
  ${_real_couchdb_src}/src/mapreduce
  deps/ns_babysitter/ebin
  deps/ns_ssl_proxy/ebin)
IF (_failure)
  MESSAGE (FATAL_ERROR "failed running dialyzer")
ENDIF (_failure)
