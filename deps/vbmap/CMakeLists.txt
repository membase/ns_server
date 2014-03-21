SET (VBMAP_SRCS
  engine_dummy.go
  engine_glpk.go
  engine_maxflow.go
  graph.go
  main.go
  utils.go
  vbmap_balance.go
  vbmap_common.go
  vbmap.go
  vbmap_test.go)

GoBuild (TARGET ns_vbmap OUTPUT vbmap SOURCES ${VBMAP_SRCS} INSTALL_PATH bin)
