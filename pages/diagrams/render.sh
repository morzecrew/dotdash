#!/bin/sh
# Renders each diagram here twice, for the site's light and dark schemes, into
# docs/assets/diagrams. Pages show one or the other with #only-light and
# #only-dark. Run it after changing a .d2 file, and commit the SVGs: the site's
# build doesn't run d2.
set -eu
cd "$(dirname "$0")"
out=../docs/assets/diagrams
for f in *.d2; do
  n=${f%.d2}
  d2 --theme 0 --pad 24 "$f" "$out/$n.light.svg"
  d2 --theme 200 --pad 24 "$f" "$out/$n.dark.svg"
done
