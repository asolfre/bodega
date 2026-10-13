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
exit $ok
