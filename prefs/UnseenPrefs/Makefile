ARCHS := arm64 arm64e
TARGET := iphone:clang:16.5:15.0

INSTALL_TARGET_PROCESSES := Preferences

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := UnseenPrefs

UnseenPrefs_FILES += UnseenRootListController.mm
UnseenPrefs_CFLAGS += -fobjc-arc
UnseenPrefs_FRAMEWORKS += UIKit
UnseenPrefs_PRIVATE_FRAMEWORKS += Preferences
UnseenPrefs_INSTALL_PATH += /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
