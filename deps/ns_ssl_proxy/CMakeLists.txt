REBAR (TARGET ns_ssl_proxy DEPENDS ale)
ADD_DEPENDENCIES (ns_realclean ns_ssl_proxy-clean)
INSTALL (DIRECTORY ebin DESTINATION "${INST_LIBDIR}/ns_ssl_proxy")
