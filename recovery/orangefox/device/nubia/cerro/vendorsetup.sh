#
# OrangeFox vendorsetup for cerro
#
FDEVICE="cerro"
fox_get_target_device() {
  local chkdev=$(echo "$BASH_SOURCE" | grep -w "$FDEVICE")
  if [ -n "$chkdev" ]; then
    FOX_BUILD_DEVICE="$FDEVICE"
  fi
}
if [ -z "$1" -a -z "$FOX_BUILD_DEVICE" ]; then
  fox_get_target_device
fi
if [ "$1" = "$FDEVICE" -o "$FOX_BUILD_DEVICE" = "$FDEVICE" ]; then
  export FOX_VARIANT="A14"
  export FOX_USE_TWRP_RECOVERY_IMAGE_BUILDER=1
  export FOX_DELETE_AROMAFM=1
  export FOX_USE_TAR_BINARY=1
  export FOX_USE_SED_BINARY=1
  export FOX_USE_LZ4_BINARY=1
  export FOX_USE_ZSTD_BINARY=1
  export FOX_USE_BASH_SHELL=1
  export FOX_ASH_IS_BASH=1
  export FOX_ENABLE_APP_MANAGER=1
  export FOX_USE_NANO_EDITOR=1
  export OF_FORCE_PREBUILT_KERNEL=0
  export OF_AB_DEVICE_WITH_RECOVERY_PARTITION=1
  export TARGET_DEVICE_ALT="NX721J,nx721j,PQ83A01"
fi
