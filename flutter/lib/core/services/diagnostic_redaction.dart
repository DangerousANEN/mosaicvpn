/// Conservative export redaction. Retains timings/status/reasons, not endpoints.
/// Raw device logs stay local; this is not a guarantee for arbitrary free text.
String redactDiagnosticText(String text) {
  var safe = text.replaceAll(
    RegExp(r'''\b[a-z][a-z0-9+.-]*://[^\s<>"']+''', caseSensitive: false),
    '[URL]',
  );
  safe = safe.replaceAll(
    RegExp(r'\b(?:Bearer|Basic)\s+[^\s,;]+', caseSensitive: false),
    '[AUTH]',
  );
  safe = safe.replaceAllMapped(
    RegExp(
      r'''\b(token|access_token|refresh_token|password|passwd|secret|private_key|privatekey|api_key|apikey|authorization|cookie|uuid)["']?\s*[:=]\s*(?:"[^"\r\n]*"|'[^'\r\n]*'|[^\s,;}]+)''',
      caseSensitive: false,
    ),
    (match) => '${match[1]}=[REDACTED]',
  );
  safe = safe.replaceAll(
    RegExp(r'\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b', caseSensitive: false),
    '[ID]',
  );
  safe = safe.replaceAll(RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b'), '[IP]');
  safe = safe.replaceAll(
    RegExp(r'(?:[0-9a-f]{0,4}:){2,}[0-9a-f:.]*(?:%[a-z0-9_-]+)?', caseSensitive: false),
    '[IP]',
  );
  safe = safe.replaceAll(RegExp(r'[^\s<>"\x27]+@[^\s<>"\x27]+'), '[EMAIL]');
  safe = safe.replaceAll(
    RegExp(r'\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z][a-z0-9-]*(?::\d+)?\b', caseSensitive: false),
    '[HOST]',
  );
  return safe;
}
