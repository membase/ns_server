GET_FILENAME_COMPONENT(index_html_dir ${INDEX_HTML_FILE} DIRECTORY)

MESSAGE(STATUS "Building app.min.js and index.min.html ...")

EXECUTE_PROCESS(
  COMMAND deps/gocode/bin/minify --index-html ${INDEX_HTML_FILE}
  RESULT_VARIABLE result
  WORKING_DIRECTORY ${PROJECT_SOURCE_DIR})

IF(result)
  MESSAGE( FATAL_ERROR "Failed to build index.min.html or app.min.js. Check build logs." )
ENDIF(result)
