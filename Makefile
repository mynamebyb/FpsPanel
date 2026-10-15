ARCHS = arm64
TARGET := iphone:clang
SDKVERSION = latest
IPHONEOS_DEPLOYMENT_TARGET = 13.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = FpsPanel
FpsPanel_FILES = src/FpsPanel.m
FpsPanel_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FpsPanel_FRAMEWORKS = UIKit QuartzCore
# 纯 ObjC-Runtime 实现，不链接 CydiaSubstrate/ElleKit
FpsPanel_LDFLAGS = -Wno-unused-dylib

include $(THEOS_MAKE_PATH)/library.mk
