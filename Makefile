TARGET := iphone:clang:16.5:14.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := backboardd SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME += LayerPropResearch

LayerPropResearch_FILES += LayerPropResearch.mm
LayerPropResearch_CFLAGS += -fobjc-arc
LayerPropResearch_CFLAGS += -I$(THEOS_PROJECT_DIR)/include
LayerPropResearch_LDFLAGS += -L$(THEOS_PROJECT_DIR)/lib
LayerPropResearch_LIBRARIES += dobby
LayerPropResearch_FRAMEWORKS += Foundation
LayerPropResearch_FRAMEWORKS += CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
