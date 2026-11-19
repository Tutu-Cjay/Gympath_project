/// Running JavaScript in the page and receiving messages from it when the
/// app runs in a browser (on phones the WebView does this).
export 'web_bridge_stub.dart' if (dart.library.js_interop) 'web_bridge_web.dart';
