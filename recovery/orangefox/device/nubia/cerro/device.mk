#
# SPDX-License-Identifier: Apache-2.0
#

LOCAL_PATH := device/nubia/cerro

# A/B
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    dtbo \
    init_boot \
    recovery \
    vendor_boot \
    vbmeta \
    vbmeta_system

PRODUCT_PACKAGES += \
    otapreopt_script \
    checkpoint_gc \
    update_engine \
    update_engine_client \
    update_verifier \
    update_engine_sideload

# Dynamic partitions
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Fastbootd
PRODUCT_PACKAGES += \
    android.hardware.fastboot@1.1-impl-mock \
    fastbootd

# QCOM FBE decrypt (OrangeFox / TWRP)
PRODUCT_PACKAGES += \
    qcom_decrypt \
    qcom_decrypt_fbe

# Dual-boot: f2fs-tools / gptfdisk land via TWRP/OFOX common + BoardConfig
# TW_* / OF_ENABLE_LPTOOLS. Extra static bins can go under recovery/root/system/bin/.

# Soong namespaces
PRODUCT_SOONG_NAMESPACES += \
    $(LOCAL_PATH)

# Build-time kernel stub only; recovery.img is kernel-less (stock/OP12)
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/prebuilt/Image:kernel

# Copy fstab into recovery
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/recovery/root/system/etc/recovery.fstab:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/recovery.fstab \
    $(LOCAL_PATH)/recovery/root/system/etc/twrp.flags:$(TARGET_COPY_OUT_RECOVERY)/root/system/etc/twrp.flags
