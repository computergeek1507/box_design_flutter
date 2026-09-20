import 'package:flutter/material.dart';

/// Backdrop behind the design canvas / template preview.
Color canvasBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? Colors.grey.shade900 : Colors.grey.shade200;
