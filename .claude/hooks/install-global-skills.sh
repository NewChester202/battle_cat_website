#!/bin/bash
# Re-installs global Claude Code skills into ~/.claude/skills/ on every fresh
# session container, since that directory lives outside this repo and does
# not survive an environment restart.
#
# Sources are pinned to specific commit SHAs (captured after a manual
# security audit) rather than tracking each repo's latest HEAD, so a future
# upstream push to either third-party repo cannot silently change what gets
# installed here without this script being deliberately re-pinned.
set -euo pipefail

SKILLS_DIR="$HOME/.claude/skills"
WORK_DIR="$HOME/.cache/global-skills-src"
mkdir -p "$SKILLS_DIR" "$WORK_DIR"

# repo url | local dir name | pinned commit sha
SOURCES='
https://github.com/anthropics/skills|anthropics-skills|34040c9c568585f6929bedeaad110ad08f079624
https://github.com/nextlevelbuilder/ui-ux-pro-max-skill|ui-ux-pro-max-skill|7f69fed6a2717900085f1bc3b263721f8ba025e2
'

fetch_pinned() {
  local url="$1" dir="$2" sha="$3" path="$WORK_DIR/$dir"
  if [ -d "$path/.git" ] && [ "$(git -C "$path" rev-parse HEAD 2>/dev/null)" = "$sha" ]; then
    return 0
  fi
  rm -rf "$path"
  git init -q "$path"
  git -C "$path" remote add origin "$url"
  GIT_LFS_SKIP_SMUDGE=1 git -C "$path" fetch --depth 1 origin "$sha"
  git -C "$path" checkout -q FETCH_HEAD
}

echo "$SOURCES" | while IFS='|' read -r url dir sha; do
  [ -z "$url" ] && continue
  fetch_pinned "$url" "$dir" "$sha"
done

install_skill() {
  local src="$1" name="$2"
  rm -rf "${SKILLS_DIR:?}/$name"
  mkdir -p "$SKILLS_DIR/$name"
  cp -r "$src/." "$SKILLS_DIR/$name/"
  find "$SKILLS_DIR/$name" -type d -name tests -exec rm -rf {} + 2>/dev/null || true
}

# frontend-design (Anthropic, from anthropics/skills)
install_skill "$WORK_DIR/anthropics-skills/skills/frontend-design" "frontend-design"

# 7 skills bundled in nextlevelbuilder/ui-ux-pro-max-skill
UPM_SRC="$WORK_DIR/ui-ux-pro-max-skill/.claude/skills"
for name in banner-design brand design-system design slides ui-styling ui-ux-pro-max; do
  install_skill "$UPM_SRC/$name" "$name"
done

# ui-ux-pro-max's SKILL.md invokes its script via ${CLAUDE_PLUGIN_ROOT}, which is
# only set for real plugin installs. Point it at the actual install path instead.
sed -i "s#\${CLAUDE_PLUGIN_ROOT}/\.claude/skills/ui-ux-pro-max#$HOME/.claude/skills/ui-ux-pro-max#g" \
  "$SKILLS_DIR/ui-ux-pro-max/SKILL.md"

# brand, design-system, design, and ui-styling invoke their scripts with bare
# relative paths (e.g. `python scripts/foo.py`), which only resolve when the
# cwd happens to be the skill's own directory. Rewrite each such invocation
# line to use the real absolute install path instead.
python3 - "$SKILLS_DIR" << 'PYEOF'
import re, os, sys

skills_dir = sys.argv[1]
pattern = re.compile(r'^(python3?|node) (scripts/\S+)')

for name in ("brand", "design-system", "design", "ui-styling"):
    path = os.path.join(skills_dir, name, "SKILL.md")
    root = os.path.join(skills_dir, name)
    if not os.path.exists(path):
        continue
    with open(path) as f:
        lines = f.readlines()
    out = []
    for line in lines:
        stripped = line.rstrip("\n")
        m = pattern.match(stripped)
        if m:
            interp, relpath = m.group(1), m.group(2)
            newpath = os.path.join(root, relpath)
            rest = stripped[m.end():]
            out.append(f'{interp} "{newpath}"{rest}\n')
        else:
            out.append(line)
    with open(path, "w") as f:
        f.writelines(out)
PYEOF

echo "Installed global skills: frontend-design, banner-design, brand, design, design-system, slides, ui-styling, ui-ux-pro-max"
