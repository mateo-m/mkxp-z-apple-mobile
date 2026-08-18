# Every patch in this directory, in file-name order. The series is
# numbered, so a new patch only needs the next number.
SYNTAX_TRANSFORM_PATCHES := $(sort $(wildcard $(SYNTAX_TRANSFORM_DIR)/*.patch))

HAVE_SYNTAX_TRANSFORM ?= 1

$(RUBY_SRC)/syntax-transform: $(RUBY_SRC)/configure.ac
ifeq ($(HAVE_SYNTAX_TRANSFORM),1)
ifeq ($(patsubst MINGW%,,$(firstword $(shell uname))),)
	cd $(RUBY_SRC) && for patch in $(SYNTAX_TRANSFORM_PATCHES); do echo "Applying $$patch"; patch -p1 -i $(PWD)/$$patch || exit 1; done
else
	cd $(RUBY_SRC) && for patch in $(SYNTAX_TRANSFORM_PATCHES); do echo "Applying $$patch"; $(GIT) apply --whitespace=fix $(PWD)/$$patch || exit 1; done
endif
endif
	touch $(RUBY_SRC)/syntax-transform
