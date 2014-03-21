ADD_SUBDIRECTORY (gen_smtp)
ADD_SUBDIRECTORY (ale)
ADD_SUBDIRECTORY (erlwsh)
ADD_SUBDIRECTORY (mlockall)
ADD_SUBDIRECTORY (ns_babysitter)
ADD_SUBDIRECTORY (ns_ssl_proxy)

# The following deps use Go. To make the build as flexible as possible,
# we provide pre-built binaries on supported platforms. On other platforms,
# we will attempt to compile them.
IF (APPLE)
  INSTALL (PROGRAMS "${PROJECT_SOURCE_DIR}/priv/i386-darwin-vbmap" DESTINATION "bin" RENAME "vbmap")
  INSTALL (PROGRAMS "${PROJECT_SOURCE_DIR}/priv/i386-darwin-generate_cert" DESTINATION "bin"
    RENAME "generate_cert")
ELSEIF (WIN32)
  INSTALL (PROGRAMS "${PROJECT_SOURCE_DIR}/priv/i386-win32-vbmap.exe" DESTINATION "bin" RENAME "vbmap.exe")
  INSTALL (PROGRAMS "${PROJECT_SOURCE_DIR}/priv/i386-win32-generate_cert.exe" DESTINATION "bin"
    RENAME "generate_cert.exe")
ELSEIF (UNIX)
  INSTALL (PROGRAMS "${PROJECT_SOURCE_DIR}/priv/i386-linux-vbmap" DESTINATION "bin" RENAME "vbmap")
  INSTALL (PROGRAMS "${PROJECT_SOURCE_DIR}/priv/i386-linux-generate_cert" DESTINATION "bin"
    RENAME "generate_cert")
ELSE (APPLE)
  ADD_SUBDIRECTORY (generate_cert)
  ADD_SUBDIRECTORY (vbmap)
ENDIF (APPLE)
