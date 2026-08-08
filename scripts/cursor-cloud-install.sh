#!/usr/bin/env bash
# Cursor Cloud Agent 向けの冪等インストールスクリプト。
# macOS 専用アプリのため Swift/Xcode ビルドは行わない。lint 用ツールのみ用意する。
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v mise >/dev/null 2>&1; then
  curl -fsSL https://mise.jdx.dev/install.sh | sh
fi

# 以降のシェルでも mise が使えるようにする
if [[ -f "${HOME}/.bashrc" ]] && ! grep -q 'mise activate' "${HOME}/.bashrc"; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "${HOME}/.bashrc"
  echo 'eval "$(mise activate bash)"' >> "${HOME}/.bashrc"
fi

eval "$(mise activate bash)"
mise trust
mise install

echo "cursor-cloud-install: mise=$(mise --version) swiftformat=$(swiftformat --version 2>/dev/null || echo missing)"
