APP := build/DLQ Monitor.app
INSTALL_DIR := $(HOME)/Applications

# The Command Line Tools ship the swift-testing macro plugin in a directory SwiftPM does not search. It sits
# next to the selected toolchain's swift (usr/bin/swift -> usr/lib/swift/host/plugins/testing).
TESTING_PLUGINS := $(abspath $(dir $(shell xcrun --find swift))../lib/swift/host/plugins/testing)
TEST_FLAGS := $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS),)

.PHONY: build test app install run once clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

app:
	scripts/build-app.sh

install: app
	mkdir -p "$(INSTALL_DIR)"
	-pkill -x DLQMonitor
	@while pgrep -x DLQMonitor >/dev/null; do sleep 0.1; done  # open fails with -600 while it quits
	rm -rf "$(INSTALL_DIR)/DLQ Monitor.app"
	cp -R "$(APP)" "$(INSTALL_DIR)/"
	open "$(INSTALL_DIR)/DLQ Monitor.app"

run: app
	-pkill -x DLQMonitor
	@while pgrep -x DLQMonitor >/dev/null; do sleep 0.1; done  # open fails with -600 while it quits
	open "$(APP)"

# One refresh of the DLQs printed to the terminal.
once: build
	"$$(swift build --show-bin-path)/DLQMonitor" --once $(ARGS)

clean:
	rm -rf .build build
