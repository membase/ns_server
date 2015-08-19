SET (ALE_VERSION "${NS_SERVER_VERSION}" CACHE STRING
  "ale version" FORCE)

CONFIGURE_FILE("${CMAKE_CURRENT_SOURCE_DIR}/src/ale.app.src.in"
  "${CMAKE_CURRENT_SOURCE_DIR}/src/ale.app.src" @ONLY)

REBAR (TARGET ale)
ADD_CUSTOM_TARGET (ale-gen-clean COMMAND "${CMAKE_COMMAND}" -E remove -f "${CMAKE_CURRENT_SOURCE_DIR}/src/ale.app.src")
ADD_DEPENDENCIES (ns_realclean ale-clean ale-gen-clean)
INSTALL (DIRECTORY ebin DESTINATION "${INST_LIBDIR}/ale")
