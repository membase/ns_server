REBAR (TARGET ns_couchdb DEPENDS ale ns_server)
ADD_DEPENDENCIES (ns_realclean ns_couchdb-clean)
INSTALL (DIRECTORY ebin DESTINATION "${INST_LIBDIR}/ns_couchdb")
