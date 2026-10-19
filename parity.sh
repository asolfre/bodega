#!/bin/sh
# Compares what Bodega.app lists (BODEGA_DUMP file) with brew CLI output. Usage: ./parity.sh <dump.tsv>
set -u
export HOMEBREW_NO_AUTO_UPDATE=1
T="${TMPDIR:-/tmp}"
UI="$1"
# Full version field: several kegs can be installed at once (e.g. "librsvg 2.63.2 2.62.1").
{ brew list --formula --versions | sed 's/^\([^ ]*\) /formula	\1	/'
  brew list --cask --versions | sed 's/^\([^ ]*\) /cask	\1	/'; } | sort > "$T/cli.tsv"
cut -f1-3 "$UI" | sort > "$T/ui.tsv"
brew outdated -q | sed 's#.*/##' | sort > "$T/cli-out"
awk -F'\t' '$4!=""{print $2}' "$UI" | sort > "$T/ui-out"
echo "cli: $(wc -l < "$T/cli.tsv") packages, $(wc -l < "$T/cli-out") outdated"
echo "ui:  $(wc -l < "$T/ui.tsv") packages, $(wc -l < "$T/ui-out") outdated"
ok=0
diff "$T/cli.tsv" "$T/ui.tsv" && echo "LIST+VERSIONS MATCH" || ok=1
diff "$T/cli-out" "$T/ui-out" && echo "OUTDATED MATCH" || ok=1
# Active version of each formula with several kegs, from the opt link (independent of brew list).
P="$(brew --prefix)"
brew list --formula --versions | awk 'NF>2{print $1}' | while read -r n; do
  printf '%s\t%s\n' "$n" "$(basename "$(readlink "$P/opt/$n")")"
done | sort > "$T/cli-active"
awk -F'\t' '$1=="formula" && split($3,v," ")>1 {print $2"\t"$5}' "$UI" | sort > "$T/ui-active"
echo "multi-version formulae: $(wc -l < "$T/cli-active")"
diff "$T/cli-active" "$T/ui-active" && echo "ACTIVE VERSIONS MATCH" || ok=1
brew list --pinned | sort > "$T/cli-pinned"
awk -F'\t' '$6=="1"{print $2}' "$UI" | sort > "$T/ui-pinned"
echo "pinned: cli=[$(tr '\n' ' ' < "$T/cli-pinned")] ui=[$(tr '\n' ' ' < "$T/ui-pinned")]"
diff "$T/cli-pinned" "$T/ui-pinned" && echo "PINNED MATCH" || ok=1
# Untrusted: brew info --installed silently skips formulae it refuses to load (independent of receipts).
brew list --formula -1 | sort > "$T/all-f"
brew info --json=v2 --installed 2>/dev/null | python3 -c 'import json,sys;[print(f["name"]) for f in json.load(sys.stdin)["formulae"]]' | sort > "$T/loadable"
comm -23 "$T/all-f" "$T/loadable" > "$T/cli-untrusted"
awk -F'\t' '$7=="1"{print $2}' "$UI" | sort > "$T/ui-untrusted"
echo "untrusted: cli=[$(tr '\n' ' ' < "$T/cli-untrusted")] ui=[$(tr '\n' ' ' < "$T/ui-untrusted")]"
diff "$T/cli-untrusted" "$T/ui-untrusted" && echo "UNTRUSTED MATCH" || ok=1
exit $ok
