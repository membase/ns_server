REBAR (TARGET gen_smtp)
ADD_DEPENDENCIES (ns_realclean gen_smtp-clean)
INSTALL (DIRECTORY ebin DESTINATION "${INST_LIBDIR}/gen_smtp")

