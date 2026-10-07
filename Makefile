TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafeModeGuard

SafeModeGuard_FILES = Tweak.x SMGCommon.m
SafeModeGuard_CFLAGS = -fobjc-arc -Wno-unused-function
SafeModeGuard_LDFLAGS = -Wl,-undefined,dynamic_lookup
SafeModeGuard_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
