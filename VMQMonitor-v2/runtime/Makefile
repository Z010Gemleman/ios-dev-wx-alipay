# VMQ Monitor V2 运行时包 Makefile
# 同时构建通知监听 tweak (VMQListener.dylib) 与后台守护进程 (vmqmond)，
# 打成一个 deb。通过 THEOS_PACKAGE_SCHEME 切换 rootless / roothide。
#
# 用法：
#   rootless:  make -C runtime package THEOS=/root/theos          THEOS_PACKAGE_SCHEME=rootless
#   roothide:  make -C runtime package THEOS=/root/theos_roothide  THEOS_PACKAGE_SCHEME=roothide

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

# ---- 后台守护进程 vmqmond ----
TOOL_NAME = vmqmond
vmqmond_FILES = \
	daemon/main.m \
	daemon/VMQStore.m \
	daemon/VMQReporter.m \
	daemon/VMQSocketServer.m \
	common/VMQEvent.m \
	common/VMQParser.m \
	common/VMQSign.m \
	common/VMQConfig.m \
	common/VMQBoot.m
vmqmond_CFLAGS = -fobjc-arc -Icommon -Idaemon
vmqmond_LIBRARIES = sqlite3
vmqmond_FRAMEWORKS = Foundation
vmqmond_CODESIGN_FLAGS = -Sentitlements/vmqmond.plist
vmqmond_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

# ---- 通知监听 tweak ----
TWEAK_NAME = VMQListener
VMQListener_FILES = \
	listener/Tweak.x \
	listener/VMQDatagramClient.c
VMQListener_CFLAGS = -fobjc-arc -Icommon -Ilistener
VMQListener_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
