
HOST_PLAT ?= pc

ifeq ($(HOST_PLAT), pc)
CONFIG_PLATFORM_I386_PC = y
endif

ifeq ($(HOST_PLAT), tiny4412)
CONFIG_PLATFORM_ARM_tiny4412 = y
endif

ifeq ($(HOST_PLAT), raspberry)
CONFIG_PLATFORM_RASP_PI = y
endif

ifeq ($(HOST_PLAT), gk7102)
CONFIG_PLATFORM_GK7102 = y
endif

ifeq ($(HOST_PLAT), gk7202)
CONFIG_PLATFORM_GK7202 = y
endif

ifeq ($(HOST_PLAT), gk7205)
CONFIG_PLATFORM_GK7205 = y
endif

ifeq ($(HOST_PLAT), t31)
CONFIG_PLATFORM_MIPS_T31 = y
endif

ifeq ($(HOST_PLAT), nuc980_iot)
CONFIG_PLATFORM_ARM_nuc980_iot = y
endif

ifeq ($(HOST_PLAT), fh8626)
CONFIG_PLATFORM_ARM_FH8626 = y
endif

ifeq ($(HOST_PLAT), gp329)
CONFIG_PLATFORM_ARM_GP329 = y
endif

###################### Platform Related #######################
CONFIG_PLATFORM_I386_PC ?= n
CONFIG_PLATFORM_ARM_tiny4412 ?= n
CONFIG_PLATFORM_RASP_PI ?= n
CONFIG_PLATFORM_GK7102 ?= n
CONFIG_PLATFORM_GK7202 ?= n
CONFIG_PLATFORM_GK7205 ?= n
CONFIG_PLATFORM_MIPS_T31 ?= n
CONFIG_PLATFORM_ARM_nuc980_iot ?= n
CONFIG_PLATFORM_ARM_FH8626 ?= n
CONFIG_PLATFORM_ARM_GP329 ?= n

##################### Platform Configure ######################
ifeq ($(CONFIG_PLATFORM_I386_PC), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN
SUBARCH := $(shell uname -m | sed -e s/i.86/i386/)
ARCH := $(SUBARCH)
CROSS_COMPILE ?=
# DKMS passes KERNELRELEASE=$kernelver on the make command line (it always
# prepends it), so honour that and fall back to the running kernel. Without
# this, a DKMS AUTOINSTALL for a second kernel would silently build against
# the headers of the kernel that happens to be running.
KVER := $(if $(KERNELRELEASE),$(KERNELRELEASE),$(shell uname -r))
KSRC := /lib/modules/$(KVER)/build
MODDESTDIR := /lib/modules/$(KVER)/kernel/drivers/net/wireless/
INSTALL_PREFIX :=

# Match the compiler the *target* kernel was built with. CachyOS kernels are
# clang-built and reject gcc outright (-mstack-alignment=8 and friends), while
# the stock Arch kernel is gcc-built. Detecting this per KSRC keeps a plain
# `make` working on both. DKMS appends LLVM=1 itself; the duplicate is
# harmless.
KCC := $(shell if grep -qs '^CONFIG_CC_IS_CLANG=y' $(KSRC)/include/config/auto.conf \
                      $(KSRC)/.config; then echo LLVM=1; fi)
endif

ifeq ($(CONFIG_PLATFORM_ARM_tiny4412), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN
ccflags-y += -DCONFIG_4412
ARCH := arm
KVER := 3.0.86
CROSS_COMPILE :=/opt/FriendlyARM/toolschain/4.5.1/bin/arm-linux-
KSRC ?= /home/syt/share/4412/linux/linux-3.0.86
endif

ifeq ($(CONFIG_PLATFORM_RASP_PI), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN
SUBARCH := $(shell uname -m | sed -e s/i.86/i386/)
ARCH := $(SUBARCH)
ARCH := arm
CROSS_COMPILE ?=
KVER := $(shell uname -r)
KSRC := /lib/modules/$(KVER)/build
MODDESTDIR := /lib/modules/$(KVER)/kernel/drivers/net/wireless/
INSTALL_PREFIX :=
endif

ifeq ($(CONFIG_PLATFORM_GK7102), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN
ARCH := arm
KVER := 3.4.43
CROSS_COMPILE :=/opt/goke/ct_uClibc/4.6.1/usr/bin/arm-goke-linux-uclibcgnueabi-
KSRC ?= /home/syt/share/7102C/GK710X_LinuxSDK_v2.1.0/linux/kernel/3.4.43
endif

ifeq ($(CONFIG_PLATFORM_GK7202), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN -DCONFIG_PLATFORM_IPC
ARCH := arm
CROSS_COMPILE ?= arm-gk720x-linux-uclibcgnueabi-
KSRC ?= /home/syt/share/GK720X_LinuxSDK_v1.0.0/linux/kernel/3.4.43
endif

ifeq ($(CONFIG_PLATFORM_GK7205), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN -DCONFIG_PLATFORM_IPC
ARCH := arm
CROSS_COMPILE ?= /home/goke/GKIPCLinuxV100R001C00SPC030/tools/toolchains/arm-gcc6.3-linux-uclibceabi/bin/arm-gcc6.3-linux-uclibceabi-
KSRC ?= /home/goke/GKIPCLinuxV100R001C00SPC030/out/gk7205v200/linux-4.9.y
endif

ifeq ($(CONFIG_PLATFORM_MIPS_T31), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN
ARCH := mips
KVER := 3.10.14
CROSS_COMPILE :=mips-linux-gnu-
KSRC ?= /home/T31/Ingenic-SDK-T31-1.1.0-20200115/opensource/kernel
endif

ifeq ($(CONFIG_PLATFORM_ARM_nuc980_iot), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN
ARCH := arm
KVER := 4.4
CROSS_COMPILE :=/opt/nuc-arm9-linux/arm_linux_4.8/bin/arm-linux-
KSRC ?= /home/hichard/renhaibo/003.NK-980IOT/nuc980bsp/NUC980-linux-4.4.y
endif

ifeq ($(CONFIG_PLATFORM_ARM_FH8626), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN
ARCH := arm
KVER := 4.9
CROSS_COMPILE :=/opt/fullhan/toolchain/arm-fullhanv3-linux-uclibcgnueabi-b6/bin/arm-fullhanv3-linux-uclibcgnueabi-
KSRC ?= /home/fullhan/FH8626V100_IPC_V2.0.0_20200909/board_support/kernel/linux-4.9
endif

ifeq ($(CONFIG_PLATFORM_ARM_GP329), y)
ccflags-y += -DCONFIG_LITTLE_ENDIAN
ARCH := arm
KVER := 4.4
CROSS_COMPILE :=/usr/local/armv5-eabi--musl--stable-2018.02-2/bin/arm-buildroot-linux-musleabi-
KSRC ?= /home/lexin/gp329xxx_linux/sdk/os/linux-4.4.138
endif

