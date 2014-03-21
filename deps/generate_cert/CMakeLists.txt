SET (GENERATE_CERT_SRCS generate_cert.go)

GoBuild (TARGET ns_generate_cert OUTPUT generate_cert
  SOURCES ${GENERATE_CERT_SRCS}
  INSTALL_PATH bin)
