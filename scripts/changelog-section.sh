#!/bin/sh
# Print the CHANGELOG.md section for one version, without its heading, so a
# release can show what changed in it.
#
#   scripts/changelog-section.sh 0.2.1 [CHANGELOG.md]
#
# The section runs from "## [VERSION]" to the next "## " heading; leading and
# trailing blank lines are dropped. Exits 1 when the version has no section or
# the section is empty -- the release workflow relies on that to refuse a tag
# whose changes were never written down.
set -eu

version=${1:?usage: changelog-section.sh VERSION [CHANGELOG.md]}
file=${2:-CHANGELOG.md}

section=$(awk -v v="$version" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## / { exit }
  on { print }
' "$file" | awk '
  !NF { if (started) blank++; next }
  { while (blank > 0) { print ""; blank-- } started = 1; print }
')

if [ -z "$section" ]; then
  echo "changelog-section.sh: no entries for $version in $file" >&2
  exit 1
fi
printf '%s\n' "$section"
