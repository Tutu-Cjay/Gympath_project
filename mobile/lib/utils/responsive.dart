import 'dart:math';
import 'package:flutter/material.dart';

class Responsive {
  static const double _designWidth = 360.0;
  static const double _designHeight = 800.0;

  static double w(BuildContext context, double value) {
    final width = MediaQuery.of(context).size.width;
    return value * (width / _designWidth);
  }

  static double h(BuildContext context, double value) {
    final height = MediaQuery.of(context).size.height;
    return value * (height / _designHeight);
  }

  static double r(BuildContext context, double value) {
    final size = MediaQuery.of(context).size;
    final scale = min(size.width / _designWidth, size.height / _designHeight);
    return value * scale;
  }

  static double sp(BuildContext context, double value) {
    final size = MediaQuery.of(context).size;
    final scale = min(size.width / _designWidth, size.height / _designHeight);
    return value * scale;
  }
}
