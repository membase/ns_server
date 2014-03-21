# This module provides facilities for building Go code using either golang
# (preferred) or gccgo.
#
# This module defines
#  GO_FOUND, if a compiler was found

# Prevent double-definition if two projects use this script
IF (NOT FindCouchbaseGo_INCLUDED)

  IF (NOT GO_FOUND)

    # Figure out which Go compiler to use
    FIND_PROGRAM (GO_EXECUTABLE NAMES go DOC "Go executable")
    IF (GO_EXECUTABLE)
      MESSAGE ("Found Go compiler: ${GO_EXECUTABLE}")
      SET (GO_COMMAND_LINE "${GO_EXECUTABLE}" build -x)
      SET (GO_FOUND 1 CACHE BOOL "Whether Go compiler was found")
    ELSE (GO_EXECUTABLE)
      FIND_PROGRAM (GCCGO_EXECUTABLE NAMES gccgo DOC "gccgo executable")
      IF (GCCGO_EXECUTABLE)
        MESSAGE ("Found gccgo compiler: ${GCCGO_EXECUTABLE}")
        SET (GO_COMMAND_LINE "${GCCGO_EXECUTABLE}" -Os -g)
        SET (GO_FOUND 1 CACHE BOOL "Whether Go compiler was found")
      ELSE (GCCGO_EXECUTABLE)
        SET (GO_FOUND 0)
      ENDIF (GCCGO_EXECUTABLE)
    ENDIF (GO_EXECUTABLE)

    # Adds a target named <target> which produces an output executable
    # named <output> in the current binary directory.
    MACRO (GoBuild)
      IF (NOT GO_FOUND)
        MESSAGE (FATAL_ERROR "No go compiler was found!")
      ENDIF (NOT GO_FOUND)

      # PARSE_ARGUMENTS comes from FindCouchbaseErlang - make sure that
      # is included first.
      PARSE_ARGUMENTS (Go "DEPENDS;SOURCES" "TARGET;OUTPUT;INSTALL_PATH" ""
        ${ARGN})

      IF (WIN32)
        SET (Go_OUTPUT "${Go_OUTPUT}.exe")
      ENDIF (WIN32)
      SET (Go_OUTPUT_PATH "${CMAKE_CURRENT_BINARY_DIR}/${Go_OUTPUT}")
      ADD_CUSTOM_COMMAND (OUTPUT "${Go_OUTPUT_PATH}"
        COMMAND ${GO_COMMAND_LINE} -o ${Go_OUTPUT_PATH} ${Go_SOURCES}
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        DEPENDS ${Go_SOURCES} VERBATIM)
      ADD_CUSTOM_TARGET ("${Go_TARGET}" ALL
        DEPENDS "${Go_OUTPUT_PATH}" SOURCES ${Go_SOURCES})
      SET_TARGET_PROPERTIES ("${Go_TARGET}" PROPERTIES
        RUNTIME_OUTPUT_NAME "${Go_OUTPUT}"
        RUNTIME_OUTPUT_PATH "${CMAKE_CURRENT_BINARY_DIR}")

      IF (Go_DEPENDS)
        ADD_DEPENDENCIES (${Go_TARGET} ${Go_DEPENDS})
      ENDIF (Go_DEPENDS)

      IF (Go_INSTALL_PATH)
        INSTALL (PROGRAMS "${Go_OUTPUT_PATH}" DESTINATION "${Go_INSTALL_PATH}")
      ENDIF (Go_INSTALL_PATH)
    ENDMACRO (GoBuild)

    SET (FindCouchbaseGo_INCLUDED 1)
  ENDIF (NOT GO_FOUND)
ENDIF (NOT FindCouchbaseGo_INCLUDED)
