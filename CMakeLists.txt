CMAKE_MINIMUM_REQUIRED (VERSION 2.8)

PROJECT (ns_server)
LIST (APPEND CMAKE_MODULE_PATH "${PROJECT_SOURCE_DIR}/cmake_modules")
INCLUDE (FindCouchbaseErlang)
INCLUDE (FindCouchbaseGo)

# Global project variables

# Installation subdir
SET (INST_LIBDIR "lib/ns_server/erlang/lib")

SET (PRODUCT_VERSION "" CACHE STRING "Product version with build number")

# If PRODUCT_VERSION is set externally, derive product version string based on
# it and BUILD_ENTERPRISE. Otherwise, fallback to output of 'git describe'.

IF ("${PRODUCT_VERSION}" STREQUAL "")
  # Cache "git describe" output
  EXECUTE_PROCESS(COMMAND git describe
    WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
    OUTPUT_VARIABLE _ns_version
    ERROR_QUIET
    OUTPUT_STRIP_TRAILING_WHITESPACE)
ELSE ("${PRODUCT_VERSION}" STREQUAL "")
  # BUILD_ENTERPRISE variable is defined in couchbase-cli CMakeLists.txt
  IF (BUILD_ENTERPRISE)
    SET (_ns_version "${PRODUCT_VERSION}-enterprise")
  ELSE (BUILD_ENTERPRISE)
    SET (_ns_version "${PRODUCT_VERSION}-community")
  ENDIF (BUILD_ENTERPRISE)
ENDIF ("${PRODUCT_VERSION}" STREQUAL "")

  SET (NS_SERVER_VERSION "${_ns_version}" CACHE STRING
  "Couchbase server version" FORCE)
MARK_AS_ADVANCED (NS_SERVER_VERSION)

# Create rebar.config
SET (COUCHDB_SRC_DIR "${PROJECT_SOURCE_DIR}/../couchdb" CACHE PATH "Path to couchdb source")
SET (COUCHDB_BIN_DIR "${CMAKE_BINARY_DIR}/couchdb" CACHE PATH "Path to couchdb build directory")

IF (NOT EXISTS "${COUCHDB_SRC_DIR}/src/couchdb/couch_db.hrl")
  MESSAGE (FATAL_ERROR "Could not find couch_db.hrl; please re-run CMake with "
    "-DCOUCHDB_SRC_DIR=<path/to/couchdb source>")
ENDIF (NOT EXISTS "${COUCHDB_SRC_DIR}/src/couchdb/couch_db.hrl")
CONFIGURE_FILE ("${PROJECT_SOURCE_DIR}/rebar.config.in"
  "${PROJECT_SOURCE_DIR}/rebar.config" @ONLY)

# Other generated files
SET (all_img_js "${PROJECT_SOURCE_DIR}/priv/public/js/all-images.js")
ADD_CUSTOM_COMMAND (OUTPUT "${all_img_js}"
  COMMAND "${CMAKE_COMMAND}" -D "pubdir=${PROJECT_SOURCE_DIR}/priv/public"
  -D "outfile=${all_img_js}"
  -P "${PROJECT_SOURCE_DIR}/cmake_modules/build-all-images.cmake")
ADD_CUSTOM_TARGET (all_images ALL DEPENDS "${all_img_js}")

CONFIGURE_FILE ("${PROJECT_SOURCE_DIR}/src/ns_server.app.src.in"
  "${PROJECT_SOURCE_DIR}/src/ns_server.app.src" @ONLY)

FILE (WRITE "${PROJECT_BINARY_DIR}/cluster_run.configuration"
  "prefix=\"${CMAKE_INSTALL_PREFIX}\"\n")

# Various cleaning targets
ADD_CUSTOM_TARGET (ns_realclean
  COMMAND "${CMAKE_COMMAND}" -E remove -f cov.html erl_crash.dump deps/vbmap/vbmap
  COMMAND "${CMAKE_COMMAND}" -E remove_directory test/log
  COMMAND "${CMAKE_COMMAND}" -E remove_directory ebin
  COMMAND "${CMAKE_COMMAND}" -E remove_directory docs
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
  VERBATIM)
ADD_DEPENDENCIES (realclean ns_realclean)

ADD_CUSTOM_TARGET (ns_dataclean
  COMMAND "${CMAKE_COMMAND}" -E remove_directory data
  COMMAND "${CMAKE_COMMAND}" -E remove_directory coverage
  COMMAND "${CMAKE_COMMAND}" -E remove_directory couch
  COMMAND "${CMAKE_COMMAND}" -E remove_directory logs
  COMMAND "${CMAKE_COMMAND}" -E remove_directory tmp
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
  VERBATIM)

ADD_CUSTOM_TARGET (ns_distclean)
ADD_DEPENDENCIES (ns_distclean realclean ns_dataclean)


ADD_SUBDIRECTORY (deps)
Rebar (TARGET ns_server NOCLEAN
  DEPENDS ale erlwsh mlockall ns_babysitter ns_ssl_proxy gen_smtp ns_couchdb)

# Test invocation
ADD_CUSTOM_TARGET (ns_test
  "${CMAKE_COMMAND}" -D "ERL_EXECUTABLE=${ERL_EXECUTABLE}"
  -D "COUCHDB_BIN_DIR=${COUCHDB_BIN_DIR}"
  -P "${PROJECT_SOURCE_DIR}/cmake_modules/do-test.cmake"
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}"
  VERBATIM)
ADD_DEPENDENCIES (ns_test ns_server)

# Docs
ADD_CUSTOM_TARGET (ns_docs COMMAND priv/erldocs ./docs/erldocs
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}" VERBATIM)

#
# Dialyzer targets
#
# Get COUCHBASE_PLT from environment, if specified
IF (DEFINED ENV{COUCHBASE_PLT})
  SET (_couchbase_plt "$ENV{COUCHBASE_PLT}")
  SET (_force_plt FORCE)
ELSE (DEFINED ENV{COUCHBASE_PLT})
  SET (_couchbase_plt "${PROJECT_SOURCE_DIR}/couchbase.plt")
ENDIF (DEFINED ENV{COUCHBASE_PLT})
GET_FILENAME_COMPONENT (_couchbase_plt "${_couchbase_plt}" REALPATH)
SET (COUCHBASE_PLT "${_couchbase_plt}" CACHE FILEPATH
  "Full path to couchbase.plt for dialyzer targets" ${_force_plt})
MESSAGE (STATUS "COUCHBASE_PLT set to ${COUCHBASE_PLT}")

# Find OTP version
EXECUTE_PROCESS (COMMAND "${ERL_EXECUTABLE}" -noshell -eval
  "io:format(\"~s~n\", [erlang:system_info(otp_release)]), erlang:halt()."
  OUTPUT_VARIABLE OTP_RELEASE)

SET (dialyzer_args -Wno_return -Wno_improper_lists)
IF (OTP_RELEASE MATCHES "^R?1[5-9].*$$")
  LIST (APPEND dialyzer_args -Wno_undefined_callbacks)
ENDIF ()
ADD_CUSTOM_TARGET (ns_dialyzer
  COMMAND "${CMAKE_COMMAND}" -D "COUCHDB_BIN_DIR=${COUCHDB_BIN_DIR}"
  -D "DIALYZER_FLAGS=${dialyzer_args}"
  -D "COUCHBASE_PLT=${COUCHBASE_PLT}"
  -P "${PROJECT_SOURCE_DIR}/cmake_modules/do-dialyzer.cmake"
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}" VERBATIM)
ADD_DEPENDENCIES (ns_dialyzer ns_server)

SET (obsessive_args -Wunmatched_returns -Werror_handling -Wrace_conditions
  -Wbehaviours -Wunderspecs)
ADD_CUSTOM_TARGET (ns_dialyzer_obsessive
  COMMAND "${CMAKE_COMMAND}" -D "COUCHDB_BIN_DIR=${COUCHDB_BIN_DIR}"
  -D "DIALYZER_FLAGS=${obsessive_args}"
  -D "COUCHBASE_PLT=${COUCHBASE_PLT}"
  -P "${PROJECT_SOURCE_DIR}/cmake_modules/do-dialyzer.cmake"
  WORKING_DIRECTORY "${PROJECT_SOURCE_DIR}" VERBATIM)
ADD_DEPENDENCIES (ns_dialyzer_obsessive ns_server)

#
# Install
#
INSTALL (DIRECTORY ebin DESTINATION "${INST_LIBDIR}/ns_server")
INSTALL (DIRECTORY priv/public DESTINATION "${INST_LIBDIR}/ns_server/priv")
INSTALL (PROGRAMS priv/i386-linux-godu priv/i386-win32-godu.exe
  DESTINATION "${INST_LIBDIR}/ns_server/priv")

INSTALL (PROGRAMS cbbrowse_logs cbcollect_info cbreset_password DESTINATION bin)
INSTALL (PROGRAMS scripts/cbdump-config scripts/dump-guts DESTINATION bin)

# Configure custom copies of scripts for installation
SET (PREFIX "${CMAKE_INSTALL_PREFIX}")
SET (_instdir "${PROJECT_BINARY_DIR}/instfiles")
FILE (REMOVE_RECURSE "${_instdir}")
CONFIGURE_FILE (couchbase-server.sh.in "${_instdir}/couchbase-server" @ONLY)
INSTALL (PROGRAMS "${_instdir}/couchbase-server" DESTINATION bin)

SET (_etcdir "${_instdir}/etc")
FILE (MAKE_DIRECTORY "${_etcdir}")

# MacOS (at least) has a distinction between DATA_PREFIX and BIN_PREFIX, so we
# need to replace both
SET (DATA_PREFIX "${PREFIX}")
SET (BIN_PREFIX "${PREFIX}")
CONFIGURE_FILE (etc/static_config.in "${_etcdir}/couchbase/static_config" @ONLY)

FILE (WRITE "${_etcdir}/couchbase/config" "")    # create empty file
SET (_cdbetcdir "${_etcdir}/couchdb/default.d")
FILE (MAKE_DIRECTORY "${_cdbetcdir}")
SET (COUCHBASE_DB_DIR "${CMAKE_INSTALL_PREFIX}/var/lib/couchbase/data")
CONFIGURE_FILE (etc/capi.ini.in "${_cdbetcdir}/capi.ini" @ONLY)
INSTALL (DIRECTORY "${_etcdir}/" DESTINATION etc)

# Empty directory to be "installed" multiple times with varying permissions
FILE (MAKE_DIRECTORY "${_instdir}/var")
INSTALL (DIRECTORY "${_instdir}/var/" DESTINATION var/lib)
INSTALL (DIRECTORY "${_instdir}/var/" DESTINATION var/lib/couchbase
  DIRECTORY_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
  GROUP_READ GROUP_WRITE GROUP_EXECUTE)
INSTALL (DIRECTORY "${_instdir}/var/" DESTINATION var/lib/couchbase/logs
  DIRECTORY_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
  GROUP_READ GROUP_WRITE GROUP_EXECUTE)





