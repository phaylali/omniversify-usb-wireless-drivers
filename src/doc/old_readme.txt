export HOST_PLAT=pc (new environment needs to be added in platform.mak)

If you need to print information, configure CONFIG_DEBUG = y in Makefile
wext and nl80211 configure CONFIG_WIFI_FRAMEWORK in Makefile
make clean
make

// Driver loading
insmod zt9101_ztopmac.ko cfg=./wifi.cfg
If CONFIG_WIFI_FRAMEWORK in Makefile is configured as nl80211, insmod error appears Unknown symbol in module,
Please execute modprobe cfg80211 first

Firmware open failed appears when loading driver, please make sure the firmware information "fw=./fw/ZT9101_fw_r2325.bin" in wifi.cfg is correct

// Driver uninstallation
rmmod zt9101_ztopmac
