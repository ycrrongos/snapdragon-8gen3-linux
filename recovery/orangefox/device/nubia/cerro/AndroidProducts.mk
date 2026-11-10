#
# OrangeFox / TWRP product for Nubia Z60 Ultra (cerro / NX721J)
# Based on ArtistAOSP device/nubia/cerro + sm8650-common.
#

PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/twrp_cerro.mk

COMMON_LUNCH_CHOICES := \
    twrp_cerro-ap2a-eng \
    twrp_cerro-ap2a-userdebug