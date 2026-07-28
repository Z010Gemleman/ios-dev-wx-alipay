# VMQ Monitor V2 — Root Helper Makefile
# 编译为 arm64+arm64e 的命令行工具，随 App bundle 一起打进 IPA。
# TrollStore 授权此 helper 以 root 身份运行受控安装/卸载动作。

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TOOL_NAME = vmqhelper
vmqhelper_FILES = main.m
vmqhelper_CFLAGS = -fobjc-arc -I../common
vmqhelper_FRAMEWORKS = Foundation
vmqhelper_CODESIGN_FLAGS = -Sentitlements/vmqhelper.plist

include $(THEOS_MAKE_PATH)/tool.mk
