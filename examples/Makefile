PTH := .:$(PATH)
export PATH=${PTH}

all clean run:
	${foreach dir,${wildcard */}, ${MAKE} $@ -C ${dir} && } true
.PHONY: all clean run
