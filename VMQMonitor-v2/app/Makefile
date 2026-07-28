# VMQ Monitor V2 — App Makefile
# 纯代码 UIKit 应用（无 Storyboard），编译为 arm64+arm64e，供 TrollStore 安装。
# 通过 IPA 组装脚本把 helper 与两个 runtime deb 一起打进最终 IPA。

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e

# App 不走 rootless/roothide scheme（它是 TrollStore App bundle，安装在 /Applications 或容器）。
# 不设置 THEOS_PACKAGE_SCHEME。

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = VMQMonitor
VMQMonitor_RESOURCE_FILES = Info.plist
VMQMonitor_FILES = \
	main.m \
	VMQAppDelegate.m \
	VMQBaseViewController.m \
	VMQHomeViewController.m \
	VMQChannelViewController.m \
	VMQConfigViewController.m \
	VMQLogViewController.m \
	VMQRecoveryViewController.m \
	../common/VMQConfig.m \
	../common/VMQSign.m \
	../common/VMQEvent.m
VMQMonitor_CFLAGS = -fobjc-arc -I../common
VMQMonitor_FRAMEWORKS = UIKit Foundation
VMQMonitor_CODESIGN_FLAGS = -Sentitlements/VMQMonitor.plist

include $(THEOS_MAKE_PATH)/application.mk
