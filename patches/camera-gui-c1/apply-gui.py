#!/usr/bin/env python3
"""Patch only the hash-pinned libcamera0.8 qcam sources, with separate own files."""
import sys,difflib
from pathlib import Path
root=Path(sys.argv[1]);here=Path(__file__).resolve().parent
changes=[]
def edit(name,fn):
 p=root/name;old=p.read_text();new=fn(old)
 assert old!=new,name
 p.write_text(new)
 changes.extend(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
edit('src/apps/qcam/meson.build',lambda s:s.replace("qcam_sources = files([","qcam_sources = files([\n    'cerro_controls.cpp',"))
edit('src/apps/qcam/main_window.h',lambda s:s.replace('#include <memory>', '#include <memory>\n#include <array>').replace('class QAction;','class QAction;\nclass CerroControls;').replace('QToolBar *toolbar_;','QToolBar *toolbar_;\n\tstd::unique_ptr<CerroControls> cerro_;\n\tbool afLock_ = false;\n\tstd::array<float, 2> colourGains_{1.0f,1.0f}, lockedColourGains_{1.0f,1.0f};\n\tfloat gain_ = 1, lockedGain_ = 1;\n\tint exposure_ = 0, lockedExposure_ = 0;\n\tbool afVerified_ = false;'))
def main(s):
 s=s.replace('#include "main_window.h"','#include "main_window.h"\n#include "cerro_controls.h"\n#include <libcamera/control_ids.h>\n#include <QDir>\n#include <QDateTime>\n#include <QStatusBar>\n#include <QDesktopServices>\n#include <QUrl>')
 s=s.replace('title_ = "QCam " + QString::fromStdString(CameraManager::version());','title_ = QStringLiteral("相机");')
 anchor='\tstartStopAction_->setChecked(true);\n}'
 insert='''
 auto *bottom = new QToolBar(QStringLiteral("拍摄控制"), this);
 bottom->setMovable(false); addToolBar(Qt::BottomToolBarArea, bottom);
 cerro_ = std::make_unique<CerroControls>(this, centralWidget(),
  [this] { return viewfinder_->getCurrentImage(); },
  [this](bool locked) {
   if (locked) {
    lockedColourGains_ = colourGains_; lockedExposure_ = exposure_; lockedGain_ = gain_; afVerified_ = false;
    qInfo() << "Cerro AF lock snapshot" << exposure_ << gain_ << colourGains_[0] << colourGains_[1];
   }
   afLock_ = locked;
  },
  [this](const QString &message) {
   statusBar()->showMessage(message);
   if (message == QStringLiteral("对焦完成") && qEnvironmentVariableIsSet("CERRO_CAMERA_SMOKE_TEST")) {
    QTimer::singleShot(250, this, [this] {
     saveImageAs(); cerro_->setZoom(200); saveImageAs(); cerro_->setZoom(100);
     QTimer::singleShot(500, this, &MainWindow::quit);
    });
   }
  });
 bottom->addWidget(cerro_.get());
 cerro_->setFocusEnabled(camera_->id().find("/i2c-bus@1/camera@10") != std::string::npos);
 if (qEnvironmentVariableIsSet("CERRO_CAMERA_FIXED_TEST")) {
  QTimer::singleShot(5000,this,[this]{saveImageAs();});
  QTimer::singleShot(5500,this,&MainWindow::quit);
 }
 const auto &controls = camera_->controls();
 if (controls.count(&libcamera::controls::ExposureTime) && controls.count(&libcamera::controls::AnalogueGain))
  cerro_->configureExposure(controls.at(&libcamera::controls::ExposureTime).min().get<int32_t>(),
   controls.at(&libcamera::controls::ExposureTime).max().get<int32_t>(),
   controls.at(&libcamera::controls::AnalogueGain).min().get<float>(),
   controls.at(&libcamera::controls::AnalogueGain).max().get<float>());
 if (qEnvironmentVariableIsSet("CERRO_CAMERA_EXPOSURE_TEST")) {
  for (int phase=0;phase<4;phase++) {
   QTimer::singleShot(2500+phase*3000,this,[this,phase]{cerro_->exposureTest(phase);});
   QTimer::singleShot(4500+phase*3000,this,[this]{saveImageAs();});
  }
  QTimer::singleShot(15000,this,&MainWindow::quit);
 }

\tstartStopAction_->setChecked(true);
}'''
 assert s.count(anchor)>=1;s=s.replace(anchor,insert,1)
 a=s.index('int MainWindow::createToolbars()');b=s.index('\nvoid MainWindow::quit()',a)
 s=s[:a]+'''int MainWindow::createToolbars()
{
 toolbar_ = addToolBar(QStringLiteral("相机"));
 toolbar_->setMovable(false); toolbar_->setToolButtonStyle(Qt::ToolButtonTextBesideIcon);
 toolbar_->setIconSize(QSize(28,28));
 QAction *exit = toolbar_->addAction(QIcon::fromTheme("application-exit"), QStringLiteral("退出"));
 connect(exit, &QAction::triggered, this, &MainWindow::quit);
 cameraSelectButton_ = new QPushButton(QStringLiteral("后置主摄"), this);
 cameraSelectButton_->setMinimumHeight(44); cameraSelectButton_->setVisible(cm_->cameras().size() > 1);
 connect(cameraSelectButton_, &QPushButton::clicked, this, &MainWindow::switchCamera);
 if (cm_->cameras().size() > 1) toolbar_->addWidget(cameraSelectButton_);
 auto *photo = new QPushButton(QIcon::fromTheme("camera-photo"), QStringLiteral("拍照"), this);
 photo->setMinimumSize(96,48); toolbar_->addWidget(photo);
 connect(photo, &QPushButton::clicked, this, &MainWindow::saveImageAs);
 auto *album = toolbar_->addAction(QIcon::fromTheme("folder-pictures"), QStringLiteral("照片"));
 connect(album, &QAction::triggered, this, [] {
  QDesktopServices::openUrl(QUrl::fromLocalFile(QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) + QStringLiteral("/相机")));
 });
 iconPlay_ = QIcon::fromTheme("media-playback-start");
 iconStop_ = QIcon::fromTheme("media-playback-stop");
 startStopAction_ = new QAction(this); startStopAction_->setCheckable(true);
 connect(startStopAction_, &QAction::toggled, this, &MainWindow::toggleCapture);
 return 0;
}
''' + s[b:]
 s=s.replace('setWindowTitle(title_ + " : " + QString::number(fps, \'f\', 2) + " fps");','Q_UNUSED(fps);\n\tsetWindowTitle(title_);')
 s=s.replace('cameraSelectButton_->setText(QString::fromStdString(cam->id()));','cameraSelectButton_->setText(QStringLiteral("后置主摄"));').replace('cameraSelectButton_->setText(QString::fromStdString(camera_->id()));','cameraSelectButton_->setText(QStringLiteral("后置主摄"));')
 a=s.index('void MainWindow::saveImageAs()');b=s.index('\nvoid MainWindow::captureRaw()',a)
 s=s[:a]+'''void MainWindow::saveImageAs()
{
 if (cerro_ && cerro_->active()) {
  statusBar()->showMessage(QStringLiteral("正在对焦，请稍后拍照")); return;
 }
 QImage image = cerro_ ? cerro_->photoImage() : viewfinder_->getCurrentImage();
 if (image.isNull()) { statusBar()->showMessage(QStringLiteral("画面尚未就绪")); return; }
 QString path = QStandardPaths::writableLocation(QStandardPaths::PicturesLocation) + QStringLiteral("/相机");
 if (!QDir().mkpath(path)) { statusBar()->showMessage(QStringLiteral("无法创建照片目录")); return; }
 QString filename = path + "/IMG_" + QDateTime::currentDateTime().toString("yyyyMMdd_HHmmss_zzz") + ".jpg";
 QImageWriter writer(filename, "jpeg"); writer.setQuality(95);
 if (!writer.write(image)) {
  statusBar()->showMessage(QStringLiteral("保存失败：") + writer.errorString()); return;
 }
 statusBar()->showMessage(QStringLiteral("已保存：") + filename);
 qInfo() << "Cerro photo saved" << filename << image.size();
}
''' +s[b:]
 s=s.replace('\tviewfinder_->stop();','\tif (cerro_) cerro_->stop();\n\tviewfinder_->stop();')
 s=s.replace('\tviewfinder_->render(buffer, mappedBuffers_[buffer].get());','\tviewfinder_->render(buffer, mappedBuffers_[buffer].get());\n\tif (cerro_) cerro_->onFrame();')
 s=s.replace('\t/* Process buffers. */','''
 const auto &metadata = request->metadata();
 if (qEnvironmentVariableIsSet("CERRO_CAMERA_EXPOSURE_TEST") && framesCaptured_%15==0)
  qInfo() << "Cerro exposure metadata" << metadata.get(controls::ExposureTimeMode).value_or(-1)
   << metadata.get(controls::ExposureTime).value_or(-1) << metadata.get(controls::AnalogueGain).value_or(-1)
   << metadata.get(controls::ExposureValue).value_or(0);
 if (auto value = metadata.get(controls::ColourGains)) colourGains_ = {(*value)[0], (*value)[1]};
 if (auto value = metadata.get(controls::ExposureTime)) exposure_ = *value;
 if (auto value = metadata.get(controls::AnalogueGain)) gain_ = *value;
 if (afLock_ && !afVerified_ &&
     metadata.get(controls::ExposureTimeMode).value_or(-1) == controls::ExposureTimeModeManual &&
     metadata.get(controls::AnalogueGainMode).value_or(-1) == controls::AnalogueGainModeManual &&
     metadata.get(controls::AwbEnable).value_or(true) == false) {
  afVerified_ = true;
  qInfo() << "Cerro AF manual modes verified" << exposure_ << gain_ << colourGains_[0] << colourGains_[1];
 }
\t/* Process buffers. */''')
 s=s.replace('int MainWindow::queueRequest(Request *request)\n{','''int MainWindow::queueRequest(Request *request)
{
 bool manual = afLock_ || (cerro_ && cerro_->manualExposure());
 if (cerro_ && camera_->controls().count(&controls::ExposureValue))
  request->controls().set(controls::ExposureValue, cerro_->exposureEV());
 if (camera_->controls().count(&controls::ExposureTimeMode))
  request->controls().set(controls::ExposureTimeMode, manual ? controls::ExposureTimeModeManual : controls::ExposureTimeModeAuto);
 if (camera_->controls().count(&controls::AnalogueGainMode))
  request->controls().set(controls::AnalogueGainMode, manual ? controls::AnalogueGainModeManual : controls::AnalogueGainModeAuto);
 if (camera_->controls().count(&controls::AwbEnable))
  request->controls().set(controls::AwbEnable, !afLock_);
 if (manual && !afLock_ && cerro_) {
  request->controls().set(controls::ExposureTime,cerro_->exposureUs());
  request->controls().set(controls::AnalogueGain,cerro_->exposureGain());
 }
 if (afLock_) {
  if (lockedExposure_ > 0 && camera_->controls().count(&controls::ExposureTime))
   request->controls().set(controls::ExposureTime, lockedExposure_);
  if (camera_->controls().count(&controls::AnalogueGain))
   request->controls().set(controls::AnalogueGain, lockedGain_);
  if (camera_->controls().count(&controls::ColourGains))
   request->controls().set(controls::ColourGains, lockedColourGains_);
 }''')
 s=s.replace('cameraSelectButton_->setText(QStringLiteral("后置主摄"));',
  'cameraSelectButton_->setText(camera_->id().find("front@10") != std::string::npos ? QStringLiteral("前置相机") : QStringLiteral("后置主摄"));')
 anchor='int MainWindow::startCapture()\n{'
 assert anchor in s
 s=s.replace(anchor,anchor+'\n if (cerro_) cerro_->setFocusEnabled(camera_->id().find("/i2c-bus@1/camera@10") != std::string::npos);')
 return s
edit('src/apps/qcam/main_window.cpp',main)
def zoom(s):
 old='\t\tpainter.drawImage(place_, image_, image_.rect());'
 new='''
  double zoom = std::max(1.0, property("cerroZoom").toDouble());
  int w = std::max(1, static_cast<int>(image_.width() / zoom));
  int h = std::max(1, static_cast<int>(image_.height() / zoom));
  QRect source((image_.width()-w)/2, (image_.height()-h)/2, w, h);
  painter.setRenderHint(QPainter::SmoothPixmapTransform, true);
  painter.drawImage(place_, image_, source);'''
 assert old in s;s=s.replace(old,new);return s
edit('src/apps/qcam/viewfinder_qt.cpp',zoom)
edit('src/apps/qcam/main.cpp',lambda s:s.replace('mainWindow->show();','mainWindow->showMaximized();').replace('QApplication app(argc, argv);','QApplication app(argc, argv);\n\tapp.setApplicationName("cerro-camera");\n\tapp.setApplicationDisplayName(QStringLiteral("相机"));'))
for name in ['cerro_controls.h','cerro_controls.cpp']:
 (root/'src/apps/qcam'/name).write_text((here/name).read_text())
(here/'0001-qcam-cerro-controls.patch').write_text(''.join(changes))
