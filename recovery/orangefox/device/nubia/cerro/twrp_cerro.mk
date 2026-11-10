#
# SPDX-License-Identifier: Apache-2.0
#

# Inherit from common TWRP product configuration
$(call inherit-product, vendor/twrp/config/common.mk)

# Device
$(call inherit-product, device/nubia/cerro/device.mk)

PRODUCT_DEVICE := cerro
PRODUCT_NAME := twrp_cerro
PRODUCT_BRAND := nubia
PRODUCT_MODEL := NX721J
PRODUCT_MANUFACTURER := nubia
