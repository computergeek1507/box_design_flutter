import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cross_file/cross_file.dart';
import 'package:file_picker_platform_interface/file_picker_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:box_design_flutter/models/vec2.dart';
import 'package:box_design_flutter/template_maker/template_maker_screen.dart';
import 'package:box_design_flutter/template_maker/template_outline_painter.dart';

final class _MemFile extends PlatformFile {
  @override
  final String name;
  final Uint8List bytes;
  _MemFile(this.name, this.bytes);
  @override
  Uri get uri => Uri.parse('memory:$name');
  @override
  XFile get xFile => XFile.fromData(bytes, name: name);
  @override
  int? lengthSync() => bytes.length;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _FakePicker extends FilePickerPlatform with MockPlatformInterfaceMixin {
  final PlatformFile file;
  _FakePicker(this.file);
  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      [file];
}

/// A white 400x300 picture of a black-stroked L-shaped board.
Future<Uint8List> _lBoardPng() async {
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 400, 300), Paint()..color = Colors.white);
  final path = Path()
    ..moveTo(40, 40)
    ..lineTo(360, 40)
    ..lineTo(360, 160)
    ..lineTo(200, 160)
    ..lineTo(200, 260)
    ..lineTo(40, 260)
    ..close();
  canvas.drawPath(
      path,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2);
  final img = await rec.endRecording().toImage(400, 300);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  testWidgets('after Trace outline, outline points can still be selected and added', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final onError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) return;
      onError!(details);
    };
    addTearDown(() => FlutterError.onError = onError);

    final png = (await tester.runAsync(_lBoardPng))!;
    FilePickerPlatform.instance = _FakePicker(_MemFile('board.png', png));

    await tester.pumpWidget(const MaterialApp(home: TemplateMakerScreen()));
    await tester.pumpAndSettle();

    Future<void> tapAndWait(Finder f) async {
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      // Image decode / pixel readback are real async work.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
    }

    await tapAndWait(find.text('Load Image'));
    await tapAndWait(find.text('Auto-fit to outline'));
    await tapAndWait(find.text('Trace outline'));
    await tester.pump(const Duration(seconds: 5)); // let the snackbar go

    final canvas = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is TemplateOutlinePainter);
    TemplateOutlinePainter painter() => tester.widget<CustomPaint>(canvas).painter! as TemplateOutlinePainter;
    expect(painter().useCustomOutline, isTrue);
    final pts = painter().customOutlinePoints;
    expect(pts.length, 6, reason: '$pts');

    Offset px(Vec2 mm) {
      final size = tester.getSize(canvas);
      final p = painter();
      final view = p.viewRectMm;
      final scale = ((size.width - 64) / view.width).clamp(0, (size.height - 64) / view.height).toDouble();
      final origin = tester.getTopLeft(canvas) + Offset((size.width - view.width * scale) / 2, (size.height - view.height * scale) / 2);
      return origin + Offset((mm.x - view.left) * scale, (view.bottom - mm.y) * scale);
    }

    // Real mouse clicks often move a pixel or two, which makes them drags.
    Future<void> shakyClick(Offset at) async {
      final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await g.moveBy(const Offset(2, 1));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
    }

    final imageBefore = painter().imageRectMm;
    await shakyClick(px(pts[2]));
    expect(painter().selectedOutlinePointIndex, 2);
    expect(painter().customOutlinePoints[2], pts[2], reason: 'a shaky click does not move the point');

    // A real drag moves it.
    final g = await tester.startGesture(px(pts[2]), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 300)); // hold still first, like a person
    for (var i = 0; i < 6; i++) {
      await g.moveBy(const Offset(10, 8));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    final moved = painter().customOutlinePoints[2];
    expect(moved.x > pts[2].x + 5 && moved.y < pts[2].y - 5, isTrue, reason: '$moved was ${pts[2]}');
    expect(painter().imageRectMm, imageBefore, reason: 'dragging a point leaves the image alone');

    // A press whose release never arrives (seen on Windows) must not leave
    // the canvas stuck: the next press on a point still grabs *that* point.
    final lost = await tester.startGesture(px(const Vec2(50, 70)), kind: PointerDeviceKind.mouse);
    await tester.pump();
    final p4 = painter().customOutlinePoints[4];
    final g3 = await tester.startGesture(px(p4), kind: PointerDeviceKind.mouse);
    for (var i = 0; i < 6; i++) {
      await g3.moveBy(const Offset(0, 10));
      await tester.pump();
    }
    await g3.up();
    await tester.pumpAndSettle();
    expect(painter().customOutlinePoints[4].y < p4.y - 5, isTrue, reason: '${painter().customOutlinePoints[4]} was $p4');
    expect(painter().imageRectMm, imageBefore);
    await lost.cancel();

    await tester.ensureVisible(find.text('Add outline point'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add outline point'));
    await tester.pumpAndSettle();
    await shakyClick(px(const Vec2(30, 30)));
    expect(painter().customOutlinePoints.length, 7);
    await tester.tapAt(px(const Vec2(40, 30)), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle();
    expect(painter().customOutlinePoints.length, 8);
    expect(painter().imageRectMm, imageBefore, reason: 'clicks in add mode never drag the image');

    // Dragging an existing point in add mode moves it too.
    final p3 = painter().customOutlinePoints[3];
    final g2 = await tester.startGesture(px(p3), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 300));
    for (var i = 0; i < 6; i++) {
      await g2.moveBy(const Offset(-10, 0));
      await tester.pump();
    }
    await g2.up();
    await tester.pumpAndSettle();
    expect(painter().customOutlinePoints[3].x < p3.x - 5, isTrue, reason: '${painter().customOutlinePoints[3]} was $p3');
    expect(painter().customOutlinePoints.length, 8);
  });
}
