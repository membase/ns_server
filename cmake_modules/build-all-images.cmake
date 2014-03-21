# Parameters:
# pubdir: directory containing "images" subdirectory to scan for image files
# outfile: file to create

FILE (GLOB_RECURSE imgfiles RELATIVE "${pubdir}" "${pubdir}/images/*")
LIST (SORT imgfiles)
FOREACH (img ${imgfiles})
  STRING (REGEX MATCH "^images/no-preload" is_preload "${img}")
  IF (is_preload)
    LIST (REMOVE_ITEM imgfiles "${img}")
  ENDIF (is_preload)
ENDFOREACH (img)
STRING (REPLACE ";" "\", \"" img_list "${imgfiles}")
FILE (WRITE "${outfile}" "var AllImages = [\"${img_list}\"];\n")
