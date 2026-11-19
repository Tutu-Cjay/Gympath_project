import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Evaluates [js] in the page.
void runPageScript(String js) {
  globalContext.callMethod('eval'.toJS, js.toJS);
}

/// Exposes `window[channel].postMessage(text)` to the page.
void listenToPage(String channel, void Function(String message) onMessage) {
  final obj = JSObject();
  obj.setProperty('postMessage'.toJS, ((JSString m) => onMessage(m.toDart)).toJS);
  globalContext.setProperty(channel.toJS, obj);
}

void stopListening(String channel) {
  globalContext.delete(channel.toJS);
}
