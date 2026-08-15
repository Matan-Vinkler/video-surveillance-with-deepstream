# Build the Milestone 5 checkpoint-3 verification probe.
#
# This builds TEST EQUIPMENT, not the application. deepstream-app driven by the
# .txt files in configs/ remains the surveillance application; analytics_probe
# exists only because deepstream-app cannot report nvdsanalytics metadata.
#
#   make            build ../build/analytics_probe        (no MQTT)
#   make mqtt       build ../build/analytics_probe_mqtt   (MQTT enabled)
#   make clean      remove both
#
# TWO BINARIES, DELIBERATELY. The `mqtt` target links libmosquitto, whose HEADERS
# are present in the Milestone 7 container but NOT on this host -- so `make mqtt`
# has to run inside that container (scripts/ds_common.sh does it). Keeping the
# default target free of libmosquitto means the Milestone 5/7/9.2 paths use a
# binary that has never linked it, so whichever build ran last cannot change an
# earlier milestone's result.
#
# Nothing is installed and nothing under /opt is written. The DeepStream root is
# discovered through the unversioned symlink, so no version is hard-coded --
# override with DS_ROOT=/path/to/deepstream if it lives elsewhere.

DS_ROOT ?= /opt/nvidia/deepstream/deepstream

BUILD_DIR := ../build
TARGET    := $(BUILD_DIR)/analytics_probe
SRC       := analytics_probe.cpp

PKGS      := gstreamer-1.0 glib-2.0

CXXFLAGS  += -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter
CXXFLAGS  += $(shell pkg-config --cflags $(PKGS))
CXXFLAGS  += -I$(DS_ROOT)/sources/includes
CXXFLAGS  += -I$(DS_ROOT)/sources/gst-plugins/gst-nvdsanalytics

LDFLAGS   += $(shell pkg-config --libs $(PKGS))
LDFLAGS   += -L$(DS_ROOT)/lib -lnvdsgst_meta -lnvds_meta
# The DeepStream libraries are not on the default loader path, so record it in
# the binary rather than requiring callers to set LD_LIBRARY_PATH.
LDFLAGS   += -Wl,-rpath,$(DS_ROOT)/lib

MQTT_TARGET := $(BUILD_DIR)/analytics_probe_mqtt

.PHONY: all mqtt clean
all: $(TARGET)

$(TARGET): $(SRC) | $(BUILD_DIR)
	@test -d "$(DS_ROOT)/sources/includes" || { \
	    echo "ERROR: DeepStream headers not found under $(DS_ROOT)."; \
	    echo "       Set DS_ROOT=/path/to/deepstream."; exit 1; }
	$(CXX) $(CXXFLAGS) -o $@ $< $(LDFLAGS)

# Same source, same serialization, plus the MQTT transport. Fails loudly rather
# than silently producing a binary whose --mqtt-host does nothing.
mqtt: $(MQTT_TARGET)

$(MQTT_TARGET): $(SRC) | $(BUILD_DIR)
	@test -d "$(DS_ROOT)/sources/includes" || { \
	    echo "ERROR: DeepStream headers not found under $(DS_ROOT)."; \
	    echo "       Set DS_ROOT=/path/to/deepstream."; exit 1; }
	@test -f /usr/include/mosquitto.h || { \
	    echo "ERROR: mosquitto.h not found. libmosquitto-dev is present in the"; \
	    echo "       Milestone 7 container but not on the Jetson host, so this"; \
	    echo "       target must be built inside the container:"; \
	    echo "         ./scripts/run_container.sh --events-mqtt   (builds it)"; \
	    exit 1; }
	$(CXX) $(CXXFLAGS) -DHAVE_MOSQUITTO -o $@ $< $(LDFLAGS) -lmosquitto

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

clean:
	rm -f $(TARGET) $(MQTT_TARGET)
