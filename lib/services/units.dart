const double mmPerInch = 25.4;

/// Formats [mm] as e.g. "12.34mm (0.486")" -- for measurement displays where
/// showing the inch equivalent alongside the primary mm value is handy.
String mmWithInches(double mm, {int mmDecimals = 2, int inchDecimals = 3}) {
  final inches = mm / mmPerInch;
  return '${mm.toStringAsFixed(mmDecimals)}mm (${inches.toStringAsFixed(inchDecimals)}")';
}
