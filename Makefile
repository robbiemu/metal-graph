BUILD_DIR ?= build
CMAKE ?= cmake
CTEST ?= ctest

.PHONY: all configure build test clean distclean help

all: build

configure:
	$(CMAKE) -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Debug

build:
	$(CMAKE) --build $(BUILD_DIR)

test:
	$(CTEST) --test-dir $(BUILD_DIR) --output-on-failure

clean:
	$(CMAKE) --build $(BUILD_DIR) --target clean

distclean:
	rm -rf $(BUILD_DIR)

help:
	@echo "Targets:"
	@echo "  make configure   Configure CMake into $(BUILD_DIR)"
	@echo "  make build       Build the project"
	@echo "  make test        Run tests"
	@echo "  make clean       Clean build outputs"
	@echo "  make distclean   Remove the build directory"
