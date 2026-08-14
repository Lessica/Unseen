TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := backboardd SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME += Unseen

Unseen_FILES += Unseen.mm
Unseen_CFLAGS += -fobjc-arc
Unseen_CFLAGS += -I$(THEOS_PROJECT_DIR)/include
Unseen_LDFLAGS += -L$(THEOS_PROJECT_DIR)/lib
Unseen_LIBRARIES += dobby
Unseen_FRAMEWORKS += Foundation
Unseen_FRAMEWORKS += CoreFoundation

SUBPROJECTS += prefs
ifneq ($(filter DEBUG,$(THEOS_SCHEMA)),)
SUBPROJECTS += testapp
endif

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
