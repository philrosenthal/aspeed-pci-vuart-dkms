#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# Build the module against several kernel versions. For maintainers, not
# needed to install.
#
# Usage: dev/build-matrix.sh LINUX_GIT_DIR TAG...
#   e.g. dev/build-matrix.sh ~/linux v6.8 v6.12 v6.17 v6.19 v7.0
#
# Each tag gets a worktree under dev/out/ with an x86_64 defconfig and
# modules_prepare, which is enough to compile and link the module (modpost
# warns about the kernel symbols, since there is no Module.symvers).

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=$HERE/dev/out
GIT=${1:?usage: $0 LINUX_GIT_DIR TAG...}
shift

mkdir -p "$OUT"
fail=0
for tag in "$@"; do
	tree=$OUT/linux-$tag
	if [ ! -e "$tree/.config" ]; then
		echo "== preparing $tag"
		git -C "$GIT" worktree add --quiet --detach "$tree" "$tag"
		make -C "$tree" -s x86_64_defconfig
		make -C "$tree" -s -j"$(nproc)" modules_prepare
	fi
	echo "== building against $tag"
	rm -rf "$OUT/mod-$tag"
	cp -r "$HERE/dkms" "$OUT/mod-$tag"
	if make -C "$tree" M="$OUT/mod-$tag" W=1 KBUILD_MODPOST_WARN=1 modules \
		>"$OUT/build-$tag.log" 2>&1; then
		grep -E "warning|error" "$OUT/build-$tag.log" |
			grep -v "undefined!\|Module.symvers is missing\|unresolved symbol\|KBUILD_MODPOST_WARN\|You may get" || true
		echo "   ok: $(ls "$OUT/mod-$tag"/*.ko)"
	else
		cat "$OUT/build-$tag.log"
		echo "   FAILED ($OUT/build-$tag.log)"
		fail=1
	fi
done
exit $fail
