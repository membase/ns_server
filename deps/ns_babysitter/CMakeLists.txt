REBAR (TARGET ns_babysitter DEPENDS ale)
ADD_DEPENDENCIES (ns_realclean ns_babysitter-clean)
INSTALL (DIRECTORY ebin DESTINATION "${INST_LIBDIR}/ns_babysitter")

