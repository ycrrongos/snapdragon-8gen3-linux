/* SPDX-License-Identifier: GPL-2.0-or-later */
#include "cerro_controls.h"
#include <algorithm>
#include <cmath>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <QDir>
#include <QFile>
#include <QHBoxLayout>
#include <QVBoxLayout>
#include <QDebug>

CerroControls::CerroControls(QWidget *parent, QWidget *viewfinder,
 std::function<QImage()> image, std::function<void(bool)> lock,
 std::function<void(const QString &)> status)
 : QWidget(parent), viewfinder_(viewfinder), image_(image), lock_(lock), status_(status)
{
 auto *layout = new QVBoxLayout(this);
 layout->setContentsMargins(12, 4, 12, 8);
 auto *focus = new QHBoxLayout;
 autoButton_ = new QPushButton(QStringLiteral("自动对焦"), this);
 autoButton_->setMinimumHeight(44);
 focus->addWidget(autoButton_);
 focus->addWidget(new QLabel(QStringLiteral("远"), this));
 focusSlider_ = new QSlider(Qt::Horizontal, this);
 focusSlider_->setRange(0, 100); focusSlider_->setMinimumWidth(80);
 focus->addWidget(focusSlider_, 1);
 focus->addWidget(new QLabel(QStringLiteral("近"), this));
 layout->addLayout(focus);
 auto *zoom = new QHBoxLayout;
 zoom->addWidget(new QLabel(QStringLiteral("数字变焦"), this));
 zoomSlider_ = new QSlider(Qt::Horizontal, this);
 zoomSlider_->setRange(100, 400); zoomSlider_->setValue(100);
 zoomSlider_->setMinimumWidth(80); zoom->addWidget(zoomSlider_, 1);
 zoomLabel_ = new QLabel(QStringLiteral("1.0×"), this);
 zoom->addWidget(zoomLabel_); layout->addLayout(zoom);
 auto *exposure = new QHBoxLayout;
 manualExposure_ = new QCheckBox(QStringLiteral("手动曝光"), this);
 exposure->addWidget(manualExposure_);
 exposure->addWidget(new QLabel(QStringLiteral("亮暗"), this));
 evSlider_ = new QSlider(Qt::Horizontal, this); evSlider_->setRange(-40, 20); evSlider_->setValue(0);
 exposure->addWidget(evSlider_,1); evLabel_ = new QLabel(QStringLiteral("0.0 EV"),this); exposure->addWidget(evLabel_);
 layout->addLayout(exposure);
 auto *manualRow = new QHBoxLayout;
 manualRow->addWidget(new QLabel(QStringLiteral("快门"),this));
 shutterSlider_ = new QSlider(Qt::Horizontal,this); shutterSlider_->setRange(0,100); shutterSlider_->setValue(80);
 manualRow->addWidget(shutterSlider_,1); shutterLabel_ = new QLabel(this); manualRow->addWidget(shutterLabel_);
 manualRow->addWidget(new QLabel(QStringLiteral("增益"),this));
 gainSlider_ = new QSlider(Qt::Horizontal,this); gainSlider_->setRange(10,160);gainSlider_->setValue(10);
 manualRow->addWidget(gainSlider_,1);gainLabel_ = new QLabel(this);manualRow->addWidget(gainLabel_);
 layout->addLayout(manualRow);
 auto updateExposure = [this] {
  stop();
  bool manualMode = this->manualExposure(); evSlider_->setEnabled(!manualMode);
  shutterSlider_->setEnabled(manualMode);gainSlider_->setEnabled(manualMode);
  evLabel_->setText(QString::number(exposureEV(),'f',1)+QStringLiteral(" EV"));
  int us=exposureUs();
  shutterLabel_->setText(us < 10000 ? "1/"+QString::number(1000000/std::max(1,us))+QStringLiteral(" 秒") : QString::number(us/1000.0,'f',1)+QStringLiteral(" 毫秒"));
  gainLabel_->setText(QString::number(exposureGain(),'f',1)+QStringLiteral("×"));
 };
 connect(manualExposure_, &QCheckBox::toggled,this,[updateExposure](bool){updateExposure();});
 connect(evSlider_, &QSlider::valueChanged,this,[updateExposure](int){updateExposure();});
 connect(shutterSlider_, &QSlider::valueChanged,this,[updateExposure](int){updateExposure();});
 connect(gainSlider_, &QSlider::valueChanged,this,[updateExposure](int){updateExposure();});
 updateExposure();
 connect(autoButton_, &QPushButton::clicked, this, [this] { autofocus(); });
 connect(focusSlider_, &QSlider::valueChanged, this, [this](int p) { manual(p); });
 connect(zoomSlider_, &QSlider::valueChanged, this, [this](int p) { setZoom(p); });
 for (const QString &entry : QDir("/sys/class/video4linux").entryList({"v4l-subdev*"}, QDir::Dirs)) {
  QFile name("/sys/class/video4linux/" + entry + "/name");
  if (!name.open(QIODevice::ReadOnly) || !name.readAll().startsWith("ak7316-cerro "))
   continue;
  lens_ = ::open(("/dev/" + entry).toLocal8Bit().constData(), O_RDWR | O_CLOEXEC);
  break;
 }
 if (lens_ >= 0) {
  v4l2_queryctrl query{}; query.id = V4L2_CID_FOCUS_ABSOLUTE;
  if (::ioctl(lens_, VIDIOC_QUERYCTRL, &query) == 0) {
   minimum_ = query.minimum; maximum_ = query.maximum;
  }
  v4l2_control control{V4L2_CID_FOCUS_ABSOLUTE, 0};
  if (::ioctl(lens_, VIDIOC_G_CTRL, &control) == 0)
   original_ = control.value;
 }
 if (lens_ < 0 || minimum_ < 1 || maximum_ <= minimum_ || maximum_ > 1023) {
  if (lens_ >= 0) ::close(lens_);
  lens_ = -1; autoButton_->setEnabled(false); focusSlider_->setEnabled(false);
  status_(QStringLiteral("镜头对焦暂不可用"));
 } else {
  focusSlider_->blockSignals(true);
  focusSlider_->setValue((original_ - minimum_) * 100 / (maximum_ - minimum_));
  focusSlider_->blockSignals(false);
 }
}
CerroControls::~CerroControls()
{
 stop();
 if (lens_ >= 0) ::close(lens_);
}
bool CerroControls::move(int position)
{
 if (lens_ < 0 || position < minimum_ || position > maximum_) return false;
 v4l2_control control{V4L2_CID_FOCUS_ABSOLUTE, position};
 if (::ioctl(lens_, VIDIOC_S_CTRL, &control) < 0) return false;
 v4l2_control readback{V4L2_CID_FOCUS_ABSOLUTE, 0};
 return ::ioctl(lens_, VIDIOC_G_CTRL, &readback) == 0 && readback.value == position;
}
void CerroControls::manual(int percent)
{
 stop(); initial_ = true;
 if (!move(minimum_ + (maximum_ - minimum_) * percent / 100))
  status_(QStringLiteral("对焦调整失败"));
 else status_(QStringLiteral("手动对焦"));
}
void CerroControls::autofocus()
{
 if (lens_ < 0 || focusing_) return;
 v4l2_control control{V4L2_CID_FOCUS_ABSOLUTE, 0};
 if (::ioctl(lens_, VIDIOC_G_CTRL, &control) < 0) return;
 original_ = control.value; best_ = original_; bestScore_ = -1;
 phase_ = 0; index_ = 0; positions_.clear();
 const int step = std::max(16, (maximum_ - minimum_) / 8);
 for (int p = minimum_; p < maximum_; p += step) positions_.push_back(p);
 positions_.push_back(maximum_);
 focusing_ = true; initial_ = true; lock_(true);
 autoButton_->setText(QStringLiteral("正在对焦…")); focusSlider_->setEnabled(false);
 status_(QStringLiteral("正在对焦，请保持手机平稳"));
 nextPosition(); settle_ = 12; /* Allow queued AE/AWB lock requests to reach the sensor. */
}
void CerroControls::nextPosition()
{
 if (!move(positions_[index_])) { finish(false); return; }
 settle_ = 8; /* Drain actual frames queued before the lens position change. */
}
double CerroControls::contrast(const QImage &input)
{
 QImage im = input.convertToFormat(QImage::Format_Grayscale8);
 if (im.isNull() || im.width() < 32 || im.height() < 32) return -1;
 long double energy = 0, sum = 0; int count = 0;
 const int x0 = im.width() / 10, x1 = im.width() * 9 / 10;
 const int y0 = im.height() / 6, y1 = im.height() * 5 / 6;
 for (int y = y0; y < y1; y += 3) {
  const uchar *row = im.constScanLine(y), *up = im.constScanLine(y - 1), *down = im.constScanLine(y + 1);
  for (int x = x0; x < x1; x += 3) {
   double lap = 4 * row[x] - row[x - 1] - row[x + 1] - up[x] - down[x];
   energy += lap * lap; sum += row[x]; count++;
  }
 }
 if (!count || sum / count < 3) return -1;
 double mean = sum / count;
 return energy / count / (mean * mean);
}
void CerroControls::onFrame()
{
 frames_++;
 if (!initial_ && frames_ >= 45 && !qEnvironmentVariableIsSet("CERRO_CAMERA_EXPOSURE_TEST")) autofocus();
 if (!focusing_ || --settle_ > 0) return;
 double score = contrast(image_());
 qInfo() << "Cerro AF position" << positions_[index_] << "contrast" << score;
 if (score < 0) { finish(false); return; }
 if (score > bestScore_) { bestScore_ = score; best_ = positions_[index_]; }
 if (++index_ < static_cast<int>(positions_.size())) { nextPosition(); return; }
 if (phase_ == 0) {
  positions_.clear(); phase_ = 1; index_ = 0;
  for (int p = std::max(minimum_, best_ - 64); p <= std::min(maximum_, best_ + 64); p += 16)
   positions_.push_back(p);
  nextPosition(); return;
 }
 finish(true);
}
void CerroControls::finish(bool success)
{
 bool moved = move(success ? best_ : original_);
 focusing_ = false; lock_(false); focusSlider_->setEnabled(lens_ >= 0);
 autoButton_->setText(QStringLiteral("自动对焦"));
 focusSlider_->blockSignals(true);
 focusSlider_->setValue(((success ? best_ : original_) - minimum_) * 100 / (maximum_ - minimum_));
 focusSlider_->blockSignals(false);
 status_(success && moved ? QStringLiteral("对焦完成") : QStringLiteral("未能完成对焦，请重试"));
 qInfo() << "Cerro AF finished" << success << moved << "position" << best_ << "contrast" << bestScore_;
}
void CerroControls::stop()
{
 if (focusing_) finish(false);
}
void CerroControls::setZoom(int percent)
{
 zoom_ = std::clamp(percent, 100, 400) / 100.0;
 zoomLabel_->setText(QString::number(zoom_, 'f', 1) + QStringLiteral("×"));
 viewfinder_->setProperty("cerroZoom", zoom_); viewfinder_->update();
}
QImage CerroControls::photoImage()
{
 QImage im = image_();
 if (im.isNull()) return {};
 int w = std::max(1, static_cast<int>(im.width() / zoom_));
 int h = std::max(1, static_cast<int>(im.height() / zoom_));
 return im.copy((im.width() - w) / 2, (im.height() - h) / 2, w, h);
}

void CerroControls::configureExposure(int minimum,int maximum,float gainMinimum,float gainMaximum)
{
 exposureMinimum_=std::max(1,minimum);exposureMaximum_=std::max(exposureMinimum_,maximum);
 gainMinimum_=gainMinimum;gainMaximum_=gainMaximum;
 gainSlider_->setRange(std::ceil(gainMinimum*10),std::floor(gainMaximum*10));
 manualExposure_->setEnabled(true);
}
bool CerroControls::manualExposure() const { return manualExposure_->isChecked(); }
int CerroControls::exposureUs() const
{
 return std::clamp(static_cast<int>(std::round(exposureMinimum_*std::pow(static_cast<double>(exposureMaximum_)/exposureMinimum_,shutterSlider_->value()/100.0))),exposureMinimum_,exposureMaximum_);
}
float CerroControls::exposureGain() const { return std::clamp(gainSlider_->value()/10.0f,gainMinimum_,gainMaximum_); }
float CerroControls::exposureEV() const { return evSlider_->value()/10.0f; }
void CerroControls::exposureTest(int phase)
{
 if (phase==0) { manualExposure_->setChecked(true);shutterSlider_->setValue(75);gainSlider_->setValue(20); }
 else if (phase==1) { shutterSlider_->setValue(100);gainSlider_->setValue(80); }
 else if (phase==2) { manualExposure_->setChecked(false);evSlider_->setValue(-20); }
 else if (phase==3) { evSlider_->setValue(0); }
}
