include ../support/include.mk

ifdef WITH_DOCS
ALL_TARGET := $(EBIN_FILES)
else
ALL_TARGET := $(EBIN_FILES_NO_DOCS)
endif

all: $(ALL_TARGET)

.DEFAULT_GOAL := all

debug:
	$(MAKE) DEBUG=-DDEBUG

clean:
	rm -rf $(EBIN_FILES_NO_DOCS)

.PHONY: all debug clean
