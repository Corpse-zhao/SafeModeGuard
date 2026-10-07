TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = SafeModeGuardPrefs
SafeModeGuardPrefs_INSTALL_PATH = /Library/PreferenceBundles

SafeModeGuardPrefs_FILES = SMRootListController.m
SafeModeGuardPrefs_CFLAGS = -fobjc-arc -Wno-unused-function
SafeModeGuardPrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
SafeModeGuardPrefs_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/bundle.mk

after-install::
	install.exec "killall -9 Preferences || true"
