// Installed into the page by page.rs on every read: numbers the interactive
// elements, keeps them under window.__sivrad, and describes the page.
(() => {
  const S = (window.__sivrad = window.__sivrad || {});
  const visible = (el) => {
    if (!el.isConnected) return false;
    const st = getComputedStyle(el);
    if (st.visibility === "hidden" || st.display === "none" || st.opacity === "0") return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };
  const text = (s) => (s || "").replace(/\s+/g, " ").trim();
  const label = (el) => {
    const aria = el.getAttribute("aria-label");
    if (aria) return text(aria);
    const by = el.getAttribute("aria-labelledby");
    if (by) {
      const t = by.split(/\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((e) => e.innerText).join(" ");
      if (text(t)) return text(t);
    }
    if (el.id) {
      const l = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
      if (l && text(l.innerText)) return text(l.innerText);
    }
    const wrap = el.closest("label");
    if (wrap && text(wrap.innerText)) return text(wrap.innerText);
    return text(el.innerText || el.value || el.placeholder || el.title || el.alt || el.name || "");
  };
  const SELECTOR = 'a[href], button, input, select, textarea, summary, [role="button"], [role="link"], [role="tab"], [role="menuitem"], [role="option"], [role="checkbox"], [role="radio"], [role="switch"], [role="combobox"], [contenteditable="true"], [onclick]';
  S.read = (offset, slice) => {
    const els = [];
    const lines = [];
    for (const el of document.querySelectorAll(SELECTOR)) {
      if (!visible(el) || el.disabled) continue;
      if (el.closest("[aria-hidden='true']")) continue;
      const n = els.push(el);
      let kind = el.getAttribute("role") || el.tagName.toLowerCase();
      if (kind === "input") kind = `input:${el.type || "text"}`;
      let desc = `[${n}] ${kind} "${label(el).slice(0, 80)}"`;
      if (kind.startsWith("input") || kind === "textarea") {
        if (el.value && el.type !== "password") desc += ` value="${text(el.value).slice(0, 60)}"`;
        if (el.placeholder && !el.value) desc += ` placeholder="${text(el.placeholder).slice(0, 40)}"`;
        if (el.checked) desc += " checked";
      }
      if (kind === "select") {
        const opts = Array.from(el.options).slice(0, 12).map((o) => o.text.trim()).join(" | ");
        desc += ` selected="${el.options[el.selectedIndex]?.text?.trim() || ""}" options: ${opts}`;
      }
      if (kind === "a" && el.href && !el.href.startsWith("javascript:")) {
        const href = el.getAttribute("href");
        if (href && href.length < 100) desc += ` -> ${href}`;
      }
      lines.push(desc);
      if (lines.length >= 150) {
        lines.push(`... ${document.querySelectorAll(SELECTOR).length - 150} more not shown; scroll or use a more specific page`);
        break;
      }
    }
    S.els = els;
    const body = text(document.body ? document.body.innerText : "");
    return {
      title: document.title,
      url: location.href,
      elements: lines,
      text: body.slice(offset, offset + slice),
      textLength: body.length,
    };
  };
  const pick = (n) => {
    const el = S.els && S.els[n - 1];
    if (!el) return [null, `no element [${n}]; read the page first (numbers change with every read)`];
    if (!el.isConnected) return [null, `element [${n}] is gone from the page; read it again`];
    return [el, null];
  };
  S.click = (n) => {
    const [el, err] = pick(n);
    if (err) return err;
    el.scrollIntoView({ block: "center" });
    el.focus();
    el.click();
    return "ok";
  };
  S.focus = (n) => {
    const [el, err] = pick(n);
    if (err) return err;
    el.scrollIntoView({ block: "center" });
    el.focus();
    if ("value" in el && el.tagName !== "SELECT") {
      el.select ? el.select() : null;
      const setter = Object.getOwnPropertyDescriptor(el.__proto__, "value")?.set;
      setter ? setter.call(el, "") : (el.value = "");
      el.dispatchEvent(new Event("input", { bubbles: true }));
    } else if (el.isContentEditable) {
      document.execCommand("selectAll");
      document.execCommand("delete");
    }
    return "ok";
  };
  S.select = (n, value) => {
    const [el, err] = pick(n);
    if (err) return err;
    if (el.tagName !== "SELECT") return `element [${n}] is not a select`;
    const opt = Array.from(el.options).find((o) => o.value === value || o.text.trim() === value);
    if (!opt) return `no option "${value}"; options: ${Array.from(el.options).map((o) => o.text.trim()).join(" | ")}`;
    el.value = opt.value;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return "ok";
  };
})();
