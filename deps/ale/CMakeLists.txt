REBAR (TARGET ale)

SET (ale_app_src "${CMAKE_CURRENT_SOURCE_DIR}/src/ale.app.src")
ADD_CUSTOM_TARGET (ale-cfg DEPENDS "${ale_app_src}")
ADD_CUSTOM_COMMAND (OUTPUT "${ale_app_src}"
  COMMAND "${CMAKE_COMMAND}" -D "INPUT_FILE=${ale_app_src}.in"
  -D "OUTPUT_FILE=${ale_app_src}"
  -D "SEARCH=ALE_VERSION"
  -D "REPLACE=${NS_SERVER_VERSION}"
  -P "${PROJECT_SOURCE_DIR}/cmake_modules/string-replace.cmake"
  VERBATIM)
ADD_DEPENDENCIES (ale ale-cfg)

ADD_CUSTOM_TARGET (ale-gen-clean COMMAND "${CMAKE_COMMAND}" -E remove -f "${CMAKE_CURRENT_SOURCE_DIR}/src/ale.app.src")
ADD_DEPENDENCIES (ns_realclean ale-clean ale-gen-clean)
INSTALL (DIRECTORY ebin DESTINATION "${INST_LIBDIR}/ale")
