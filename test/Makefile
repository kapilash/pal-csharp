.PHONY: all clean

TESTS := $(shell find . -mindepth 1 -maxdepth 1 -type d \
	! -name '_*' ! -name '.*' | sort | sed 's|^\./||')

all: $(TESTS) lint

# The §7.2 mechanical detectors, and R18.2's of emitter contortion. They run after the tests because
# the provenance lint reads what the emitter actually produced. `fst-configs.sh --check`
# is here for a different reason, which `cs-projects.sh --check` shares: an IDE config
# that disagrees with the build about what a directory contains is worse than no config at
# all, so neither is allowed to drift.
#
# `ide-build.sh` closes the other half of the C# obligation. Each directory is compiled
# above with a *stock* project, deliberately without the analyzer, because the invariant
# there is that annotated C# is ordinary C#. That leaves "the analyzer says nothing about
# a program pal-csharp accepts" unchecked -- invisible to a proof, and the first thing a
# contributor sees when they open the file.
.PHONY: lint
lint: $(TESTS)
	@bash install-fstar.sh
	@bash no-example-names.sh
	@bash diagnostic-ids.sh
	@bash provenance-lint.sh
	@bash module-refs.sh
	@bash fst-configs.sh --check
	@bash cs-projects.sh --check
	@bash ide-build.sh

# Rewrite the generated editor configuration after adding or removing a test directory:
# the F* configs that let fstar-mode open the emitted Pulse, and the C# projects that let
# a language server open the source it came from.
.PHONY: configs
configs:
	@bash fst-configs.sh
	@bash cs-projects.sh

.PHONY: $(TESTS)
$(TESTS):
	@$(MAKE) -C $@

clean:
	@for d in $(TESTS); do $(MAKE) -C $$d clean; done
