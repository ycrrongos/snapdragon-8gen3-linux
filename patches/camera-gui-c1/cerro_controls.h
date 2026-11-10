/* SPDX-License-Identifier: GPL-2.0-or-later */
#pragma once
#include <QWidget>
#include <QImage>
#include <QLabel>
#include <QSlider>
#include <QPushButton>
#include <QCheckBox>
#include <functional>
#include <vector>

class CerroControls : public QWidget
{
public:
 CerroControls(QWidget *parent, QWidget *viewfinder,
               std::function<QImage()> image, std::function<void(bool)> lock,
               std::function<void(const QString &)> status);
 ~CerroControls();
 void onFrame();
 void stop();
 void autofocus();
 QImage photoImage();
 bool active() const { return focusing_; }
 void setZoom(int percent);
 void setFocusEnabled(bool enabled);
 void configureExposure(int minimum, int maximum, float gainMinimum, float gainMaximum);
 bool manualExposure() const;
 int exposureUs() const;
 float exposureGain() const;
 float exposureEV() const;
 void exposureTest(int phase);
private:
 bool move(int position);
 void finish(bool success);
 void manual(int percent);
 void nextPosition();
 double contrast(const QImage &image);
 int lens_ = -1;
 int minimum_ = 0, maximum_ = 0, original_ = 0, best_ = 0;
 int settle_ = 0, frames_ = 0, phase_ = 0, index_ = 0;
 bool focusing_ = false, initial_ = false, focusEnabled_ = true;
 int exposureMinimum_ = 10, exposureMaximum_ = 33212;
 float gainMinimum_ = 1, gainMaximum_ = 16;
 QCheckBox *manualExposure_;
 QSlider *evSlider_, *shutterSlider_, *gainSlider_;
 QLabel *evLabel_, *shutterLabel_, *gainLabel_;
 double bestScore_ = -1, zoom_ = 1;
 std::vector<int> positions_;
 QWidget *viewfinder_;
 QSlider *focusSlider_, *zoomSlider_;
 QLabel *zoomLabel_;
 QPushButton *autoButton_;
 std::function<QImage()> image_;
 std::function<void(bool)> lock_;
 std::function<void(const QString &)> status_;
};
