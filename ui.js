// Drives Bodega through Accessibility for end-to-end checks. Needs Accessibility for the calling app.
// osascript -l JavaScript ui.js click <id> | type <id> <text> [submit] | read <id> | exists <id> | wait <id> [sec]
//                             | dialog <button title>   (presses a button in the confirmation dialog)
function run(argv) {
  var se = Application("System Events");
  var proc = se.processes.byName("Bodega");
  var cmd = argv[0], id = argv[1];

  function ident(el) { try { return el.attributes.byName("AXIdentifier").value(); } catch (e) { return null; } }
  function find(target) {
    // Depth-first with early exit, sheets first; skip columns/scroll bars (they repeat every cell).
    // Search-sheet controls are only looked for in sheets: walking the 200+ row table takes minutes.
    var sheetOnly = /^(install-|installed-|no-results|close-results)/.test(target);
    var roots = [];
    proc.windows().forEach(function (w) { try { w.sheets().forEach(function (s) { roots.push(s); }); } catch (e) {} });
    if (!sheetOnly) proc.windows().forEach(function (w) { roots.push(w); });
    function dfs(el) {
      if (ident(el) === target) return el;
      var kids; try { kids = el.uiElements(); } catch (e) { return null; }
      for (var i = 0; i < kids.length; i++) {
        var r = ""; try { r = kids[i].role(); } catch (e) {}
        if (r === "AXColumn" || r === "AXScrollBar") continue;
        var hit = dfs(kids[i]);
        if (hit) return hit;
      }
      return null;
    }
    for (var j = 0; j < roots.length; j++) { var hit = dfs(roots[j]); if (hit) return hit; }
    return null;
  }
  function need(target) {
    var el = find(target);
    if (!el) throw new Error("not found: " + target);
    return el;
  }

  if (cmd === "click") {
    var b = need(id);
    if (!b.enabled()) throw new Error("disabled: " + id);
    b.actions.byName("AXPress").perform();
    return "clicked " + id;
  }
  if (cmd === "type") {
    var f = need(id);
    proc.frontmost = true;
    f.focused = true;
    delay(0.2);
    f.value = argv[2];  // set the value directly: keystrokes would be changed by Caps Lock
    delay(0.2);
    if (argv[3] === "submit") se.keyCode(36);
    return "typed into " + id + ": " + f.value();
  }
  if (cmd === "read") { var el = need(id); try { return String(el.value()); } catch (e) { return String(el.name()); } }
  if (cmd === "exists") { return find(id) ? "yes" : "no"; }
  if (cmd === "enabled") { return need(id).enabled() ? "enabled" : "disabled"; }
  if (cmd === "sheet-text") {
    var texts = [];
    function collectText(el) {
      var r = ""; try { r = el.role(); } catch (e) {}
      if (r === "AXStaticText") { try { texts.push(String(el.value())); } catch (e) {} }
      var kids; try { kids = el.uiElements(); } catch (e) { return; }
      kids.forEach(function (k) { var kr = ""; try { kr = k.role(); } catch (e) {} if (kr !== "AXColumn" && kr !== "AXOutline" && kr !== "AXTable") collectText(k); });
    }
    proc.windows().forEach(function (w) { try { w.sheets().forEach(collectText); } catch (e) {} });
    return texts.join("\n");
  }
  if (cmd === "sheet-ids") {
    var ids = [];
    function collect(el) {
      var i = ident(el); if (i) ids.push(i);
      var kids; try { kids = el.uiElements(); } catch (e) { return; }
      kids.forEach(function (k) { var r = ""; try { r = k.role(); } catch (e) {} if (r !== "AXColumn" && r !== "AXScrollBar") collect(k); });
    }
    proc.windows().forEach(function (w) { try { w.sheets().forEach(collect); } catch (e) {} });
    return ids.join("\n");
  }
  if (cmd === "wait") {
    var limit = Date.now() + 1000 * parseFloat(argv[2] || "30");
    while (Date.now() < limit) { if (find(id)) return "appeared " + id; delay(0.5); }
    throw new Error("timeout waiting for " + id);
  }
  if (cmd === "dialog") {
    // Only sheets and non-main windows: the table rows have buttons with the same titles.
    var queue = [];
    proc.windows().forEach(function (w) {
      try { w.sheets().forEach(function (s) { queue.push(s); }); } catch (e) {}
      var n = null; try { n = w.name(); } catch (e) {}
      if (n !== "Bodega") queue.push(w);
    });
    while (queue.length) {
      var el = queue.shift(), title = null;
      try { title = el.title(); } catch (e) {}
      if (!title) try { title = el.name(); } catch (e) {}
      if (!title) try { title = el.description(); } catch (e) {}  // destructive buttons expose only this
      try { if (el.role() === "AXButton" && title === id) { el.actions.byName("AXPress").perform(); return "pressed " + id; } } catch (e) {}
      try { el.uiElements().forEach(function (k) { queue.push(k); }); } catch (e) {}
    }
    throw new Error("dialog button not found: " + id);
  }
  throw new Error("unknown command " + cmd);
}
