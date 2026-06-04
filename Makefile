# THEOS_DEVICE_IP = localhost
# THEOS_DEVICE_PORT = 2222

TARGET := iphone:clang:16.5:14.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES += backboardd SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME += LayerPropResearch

LayerPropResearch_FILES += Tweak.m
LayerPropResearch_FILES += patchfinder.c
LayerPropResearch_FILES += ProcessFilter.m
LayerPropResearch_FILES += ScreenshotActionHooks.m
LayerPropResearch_FILES += CaptureStateHooks.m
LayerPropResearch_CFLAGS += -fobjc-arc
LayerPropResearch_CFLAGS += -I$(THEOS_PROJECT_DIR)/include
LayerPropResearch_LDFLAGS += -L$(THEOS_PROJECT_DIR)/lib -ldobby -lc++
LayerPropResearch_FRAMEWORKS += Foundation
LayerPropResearch_PRIVATE_FRAMEWORKS += CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
