#!/usr/bin/env bash
# Write the report's front page, OUT_DIR/storage_report/index.html: one button per tab (Total,
# then each folder) and a switch between the overview and the cart. Each page loads only when
# its tab is opened. Run after the pages are built; a page that is missing or failed says so.
#
# Usage: bash 05_write_index.sh OUT_DIR

set -uo pipefail
if [[ $# -ne 1 ]]; then echo "Usage: bash $0 OUT_DIR" >&2; exit 1; fi
OUT_DIR="$1"; REPORT_DIR="$OUT_DIR/storage_report"; TABS="$REPORT_DIR/tabs.tsv"
[[ -f "$TABS" ]] || { echo "ERROR: not found: $TABS" >&2; exit 1; }

# The pages' state, per tab: built, failed or not built (yet)
state() { if [[ -f "$REPORT_DIR/$1/$2.html" ]]; then echo ok; elif [[ -f "$REPORT_DIR/$1/$2.failed" ]]; then echo failed; else echo missing; fi; }
TAB_JS=""
while IFS=$'\t' read -r T L R LV S F B; do
  L="${L//\\/\\\\}"; L="${L//\"/\\\"}"
  TAB_JS+="{t:\"$T\",label:\"$L\",bytes:$B,files:$F,overview:\"$(state "$T" overview)\",cart:\"$(state "$T" cart)\"},"
done < <(tail -n +2 "$TABS")
TITLE="$(awk -F'\t' 'NR == 2 { print ($1 == "total" ? "several folders" : $2) }' "$TABS")"
BUILT="$(date '+%Y-%m-%d %H:%M')"
RULES="$(awk '/^version:/ { gsub(/["'"'"']/, "", $2); print $2; exit }' ../rules/cleanup_rules.yaml 2> /dev/null)"
# The low-memory build (01a_build_low_memory.R) combines small files in very large scans: say so
LUMPED=""
if [[ -f "$REPORT_DIR/lumped.txt" ]]; then
  IFS=$'\t' read -r LMB LN < "$REPORT_DIR/lumped.txt"
  LUMPED=" To fit in memory, $LN files under $LMB were combined into one row per folder and file type: sizes and file counts are exact, but those small files' colours are approximate and the file lists show the combined rows."
fi

cat > "$REPORT_DIR/index.html" <<HTML
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Storage report: $TITLE</title>
<style>
  :root { --bg:#fff; --fg:#222; --muted:#666; --line:#ddd; --accent:#2C6E9B; }
  @media (prefers-color-scheme: dark) { :root { --bg:#1b1d20; --fg:#e8e8e8; --muted:#aaa; --line:#3a3d42; --accent:#7FA7C9; } }
  body { margin:0; font:14px/1.4 system-ui, sans-serif; background:var(--bg); color:var(--fg); }
  header { padding:10px 16px; border-bottom:1px solid var(--line); }
  h1 { font-size:18px; margin:0 0 6px; }
  .note { color:var(--muted); font-size:12px; }
  nav { display:flex; flex-wrap:wrap; gap:4px; margin-top:8px; }
  nav button, .views button { border:1px solid var(--line); background:transparent; color:var(--fg); padding:5px 10px; border-radius:4px; cursor:pointer; }
  nav button.on, .views button.on { background:var(--accent); border-color:var(--accent); color:#fff; }
  .views { display:flex; gap:4px; margin-top:6px; }
  iframe { width:100%; height:calc(100vh - 120px); border:0; }
  #msg { padding:24px 16px; color:var(--muted); }
</style></head>
<body>
<header>
  <h1>Storage report: $TITLE</h1>
  <div class="note">Built $BUILT, cleanup rules ${RULES:-(unknown)}. Tabs: all folders together (Total), then each folder. Keep this page in its folder: it opens the pages in the sub-folders beside it.$LUMPED</div>
  <nav id="tabs"></nav>
  <div class="views"><button id="v-overview" class="on">Overview (by time)</button><button id="v-cart">Cart and files</button></div>
</header>
<iframe id="page" title="Storage page"></iframe>
<div id="msg" hidden></div>
<script>
  const tabs = [$TAB_JS];
  let tab = tabs[0], view = "overview";
  const tib = b => (b / 1024 ** 4).toFixed(2) + " TiB";
  function show() {
    const st = tab[view], frame = document.getElementById("page"), msg = document.getElementById("msg");
    frame.hidden = st !== "ok"; msg.hidden = st === "ok";
    if (st === "ok") frame.src = tab.t + "/" + view + ".html";
    else msg.textContent = st === "failed"
      ? "This page could not be built. See " + tab.t + "/" + view + "_messages.txt in this folder."
      : "This page has not been built yet. Open this page again when the build jobs have finished.";
    document.querySelectorAll("#tabs button").forEach(b => b.classList.toggle("on", b.dataset.t === tab.t));
    document.getElementById("v-overview").classList.toggle("on", view === "overview");
    document.getElementById("v-cart").classList.toggle("on", view === "cart");
  }
  for (const t of tabs) {
    const b = document.createElement("button"); b.dataset.t = t.t;
    b.textContent = t.label + " · " + tib(t.bytes);
    b.onclick = () => { tab = t; show(); }; document.getElementById("tabs").appendChild(b);
  }
  document.getElementById("v-overview").onclick = () => { view = "overview"; show(); };
  document.getElementById("v-cart").onclick = () => { view = "cart"; show(); };
  show();
</script>
</body></html>
HTML
echo "Front page: $REPORT_DIR/index.html"
