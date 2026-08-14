ARCHS := arm64 arm64e
TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES := UnseenTest

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := UnseenTest

UnseenTest_FILES += main.m
UnseenTest_FILES += USTAppDelegate.m
UnseenTest_FILES += USTTestViewController.m
UnseenTest_CFLAGS += -fobjc-arc
UnseenTest_FRAMEWORKS += UIKit
UnseenTest_FRAMEWORKS += QuartzCore
UnseenTest_RESOURCE_DIRS += Resources
UnseenTest_RESOURCE_FILES += ../Artworks/AppIcon.png

include $(THEOS_MAKE_PATH)/application.mk
