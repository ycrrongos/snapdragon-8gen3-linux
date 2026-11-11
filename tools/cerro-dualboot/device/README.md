# Cerro Android / Linux 机内系统切换应用

**2026-11-11：用户已授权实机测试，当前优先 Linux 端。已安装 Linux GUI、导入电脑清单并读回核对 Android 缓存；实际切换后的启动与同槽验证尚在采集，不以旧电脑脚本测试代替 GUI 验收。Android APK 的 root 与完整互切验收单独记录。**

## Android 使用方式

1. 在手机内部共享存储创建 `linuxkernel` 目录，放入一个或多个已正确打包的 Cerro Linux boot `.img`。
   文件管理器显示为“内部存储/linuxkernel”；root 后端对应 `/data/media/0/linuxkernel`。
   必须是完整96MiB、header v2/stub127且带Cerro标记的boot镜像，不能放裸`Image`或压缩包。
2. 安装构建的 `cerro-system-switch-android-v2.apk`。打开“系统切换”，通过 KernelSU/Magisk 授予 root。
3. 点击刷新，选择文件，预览文件名、SHA256、当前槽与缓存槽，再明确确认切换。
4. 应用先保存两槽 boot/dtbo 原件和SHA，再复制当前 Android 两文件到非活动槽。
   复制读回通过后，清空当前槽DTBO、刷入所选Linux boot、逐个读回，最后重启。

根分区和原 Android 必须已由用户正确准备，bootloader已有可用解锁启动路径。
应用不安装Linux rootfs、不调整分区，不刷ABL/XBL/vendor_boot/vbmeta/userdata，不改变活动槽。
输入镜像先复制到root私有暂存，复核预览SHA，避免共享存储文件在写入过程中被修改。
活动boot已带Linux标记或活动DTBO已清零时，拒绝再次拿它覆盖Android缓存。

Android写入使用前台服务和唤醒锁；离开界面不自动重放写入操作。
发生失败停在有清单的阶段，不自动重启。若系统仍在Android，可用“恢复Android”完成中断恢复。

## Linux 使用方式

构建包解压后执行：

```sh
sudo apt-get install python3-gi gir1.2-gtk-3.0 pkexec
sudo sh install-linux.sh
```

打开“系统切换”，点击预览计划，再确认切换到Android。
root后端检查同一设备/活动槽/Linux根FS UUID和缓存两文件SHA，备份当前现场，
从非活动槽恢复boot/dtbo到**同一个活动槽**，读回通过后重启。

如果Linux由电脑脚本切入，尚无机内清单：把电脑私有
`backups/dualboot-swap/<serial>/state.json`复制到手机后，使用“导入电脑端互切清单”。
导入核对真实设备、槽、rootfs和缓存SHA，不刷分区；允许host记录之后合法更新过Linux内核，
但两份Android缓存必须完全一致。有现存机内清单时不覆盖。
原host备份目录继续保留，JSON和分区原件不要公开上传。

## 跨系统状态与恢复边界

Android先以root挂载已有`cerro_linux` ext4根分区，识别顶层 Debian 或本机的
`debian-root` 子目录；备份/清单写到真实 Debian 根内的
`/var/lib/cerro-dualboot-device`。Linux直接访问同一目录，不能写到外壳根的同名目录。Android的加密用户数据无须被Linux解密。
若无法挂载或UUID/分区尺寸不符，在改写boot/dtbo前停止。

每轮备份目录带`slot_a`/`slot_b`文件名、现场LABEL、SHA256SUMS；manifest采用原子替换、
每步sync及互斥锁。Linux恢复前再保存当前两槽现场。两边共用`switch-backend.sh`，
没有旧的只备份boot、不处理dtbo或偷偷set_active路径。
只接受64字符SHA、严格槽位和分区白名单；清单永不作为shell源码执行。

该目录本身在手机上也是恢复材料，不要随意删除。断电、存储I/O故障或外部同时刷机
仍可能留下中断现场；清单让恢复有据可查，不等于保证任意故障都能自动恢复。
未知/未完整写完的互斥锁会失败停止，需保留现场核对，不盲删锁再写。

## 从源码构建

电脑需要JDK11+和Android SDK35（aapt2/d8/zipalign/apksigner）：

```sh
ANDROID_SDK_ROOT=/path/to/Android/Sdk tools/cerro-dualboot/device/build-apps.sh
```

产物在`build/system-switch-apps/`：APK、Linux tar.gz与SHA256SUMS。
签名使用本地生成的开发密钥；保留本机keystore以便更新，同名旧APK若签名不同不能直接覆盖安装。
密钥和APK均不入Git。该脚本只编译/签名/打包，没有adb install、root运行、刷机或手机连接操作。

本地检查包括 Shell/Python 语法、Java 编译与 APK 签名、8项电脑互切故障场景。实机状态以文首及功能笔记为准。
