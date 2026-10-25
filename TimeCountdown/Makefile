export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:14.0
export DEBUG = 0

# Theos 默认给所有告警加 -Werror，一个 unused-function 就会整轮构建挂掉。
# 关掉它，让告警只是告警（Helium 这类工程通常也这么设）。
export GO_EASY_ON_ME = 1

# 用 runner 上的 clang 而不是 Theos 自带的工具链，避免 SDK 版本对不上
TARGET_CC := $(shell xcrun --sdk iphoneos --find clang)
TARGET_CXX := $(shell xcrun --sdk iphoneos --find clang++)
TARGET_LD := $(shell xcrun --sdk iphoneos --find clang++)

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = TimeCountdown

TimeCountdown_FILES = \
	$(wildcard src/app/*.m) \
	$(wildcard src/core/*.m) \
	$(wildcard src/core/*.mm) \
	$(wildcard src/hud/*.m)

TimeCountdown_CFLAGS = -fobjc-arc -Isrc -Isrc/app -Isrc/core -Isrc/hud -Isrc/private_headers -Wno-deprecated-declarations -Wno-error
TimeCountdown_CFLAGS += -include hud-prefix.pch
# 关掉 clang modules：开着的时候 POSIX 头（sys/stat.h 等）会被当成 module 依赖，
# 隐式声明系统函数会直接变成硬错误。Helium 也是这么设的。
TimeCountdown_USE_MODULES = 0
TimeCountdown_FRAMEWORKS = UIKit Foundation CoreGraphics CoreImage QuartzCore Vision
# 私有框架一律不参与链接：Xcode 的 iPhoneOS SDK 里并没有
# BackBoardServices / GraphicsServices / SpringBoardServices 这几个 .framework，
# 写进 _PRIVATE_FRAMEWORKS 会直接 `ld: framework not found`。
# 全部改成运行时 dlopen + dlsym（见 src/hud/HUDApp.m 的私有符号解析段），
# 以及 src/core/TDEngine.mm 的 IOSurface 段。

ifeq ($(TARGET_CODESIGN),ldid)
TimeCountdown_CODESIGN_FLAGS += -Sent.plist
else
TimeCountdown_CODESIGN_FLAGS += --entitlements ent.plist $(TARGET_CODESIGN_FLAGS)
endif

include $(THEOS_MAKE_PATH)/application.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p packages $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)cp -rp $(THEOS_STAGING_DIR)/Applications/TimeCountdown.app $(THEOS_STAGING_DIR)/Payload$(ECHO_END)
	$(ECHO_NOTHING)cd $(THEOS_STAGING_DIR); zip -qr TimeCountdown.tipa Payload; cd -;$(ECHO_END)
