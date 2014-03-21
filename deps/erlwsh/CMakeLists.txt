FILE (MAKE_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/ebin")

SET (ERLWSH_SRC
     src/erlwsh_app.erl
     src/erlwsh_deps.erl
     src/erlwsh.erl
     src/erlwsh_sup.erl
     src/erlwsh_web.erl
     src/eshell.erl
    )

SET (ERLANG_COMPILE_FLAGS +debug_info -Werror +nowarn_deprecated_function)
ERL_BUILD (erlwsh ${ERLWSH_SRC})
ADD_CUSTOM_COMMAND (TARGET erlwsh POST_BUILD
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different
  "${CMAKE_CURRENT_SOURCE_DIR}/src/erlwsh.app"
  "${CMAKE_CURRENT_SOURCE_DIR}/ebin/erlwsh.app"
  VERBATIM)

INSTALL (DIRECTORY ebin DESTINATION "${INST_LIBDIR}/erlwsh")
INSTALL (DIRECTORY priv DESTINATION "${INST_LIBDIR}/erlwsh")
