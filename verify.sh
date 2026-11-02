#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -eq 0 ]]; then
  printf '%s\n' 'ERROR: run as the desktop user, not through sudo.' >&2
  exit 1
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
config_home="$(realpath -m -- "${XDG_CONFIG_HOME:-${HOME}/.config}")"
data_home="$(realpath -m -- "${XDG_DATA_HOME:-${HOME}/.local/share}")"
local_bin="$(realpath -m -- "${HOME}/.local/bin")"
export PATH="${local_bin}:${PATH}"

repo_fingerprint() {
  {
    git -C "${repo_root}" status --porcelain=v1 --untracked-files=all
    git -C "${repo_root}" diff --binary HEAD
  } | sha256sum | cut -d ' ' -f 1
}
initial_repo_fingerprint="$(repo_fingerprint)"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $(realpath -m -- "${config_home}/nvim") == "${repo_root}/.config/nvim" ]] || fail 'Nvim config symlink is wrong'
[[ $(realpath -m -- "${config_home}/kitty") == "${repo_root}/.config/kitty" ]] || fail 'Kitty config symlink is wrong'
[[ -x ${local_bin}/nvim ]] || fail 'Nvim is missing'
[[ -x ${local_bin}/kitty ]] || fail 'Kitty is missing'
[[ -x ${local_bin}/tree-sitter ]] || fail 'tree-sitter CLI is missing'
[[ -x ${local_bin}/mdview ]] || fail 'mdview is missing'

nvim_version="$("${local_bin}/nvim" --version | sed -n '1p')"
kitty_version="$("${local_bin}/kitty" --version)"
tree_sitter_version="$("${local_bin}/tree-sitter" --version)"
[[ ${nvim_version} == 'NVIM v0.12.6'* ]] || fail "unexpected Nvim version: ${nvim_version}"
[[ ${kitty_version} == 'kitty 0.49.2'* ]] || fail "unexpected Kitty version: ${kitty_version}"
[[ ${tree_sitter_version} == 'tree-sitter 0.27.1'* ]] || fail "unexpected tree-sitter version: ${tree_sitter_version}"
printf '%s\n' "${nvim_version}" "${kitty_version}" "${tree_sitter_version}"
"${local_bin}/mdview" --help >/dev/null

font_match="$(fc-match -f '%{family}\n' 'FiraCode Nerd Font Mono')"
[[ ${font_match} == *'FiraCode Nerd Font Mono'* ]] || fail "font not found: ${font_match}"
printf 'Font: %s\n' "${font_match}"

"${data_home}/configs-mdview-venv/bin/python" -m pip check
"${data_home}/configs-mdview-venv/bin/python" -m unittest discover \
  -s "${repo_root}/tests" -p 'test_mdview.py'

export CONFIGS_REPO_ROOT="${repo_root}"
"${local_bin}/kitty" +runpy 'import os, runpy; from kitty.config import load_config; root=os.environ["CONFIGS_REPO_ROOT"]; bad=[]; load_config(root + "/.config/kitty/kitty.conf", accumulate_bad_lines=bad); assert not bad, bad; draw=runpy.run_path(root + "/.config/kitty/tab_bar.py")["draw_title"]; assert draw({"title":"  smoke  ","index":2}) == "2 smoke"'
"${local_bin}/nvim" --headless -i NONE "+lua dofile([[${repo_root}/scripts/nvim/verify.lua]])" '+qa'

[[ $(repo_fingerprint) == "${initial_repo_fingerprint}" ]] || fail 'repository changed during verification'

login_shell="${SHELL:-/bin/bash}"
[[ -x ${login_shell} ]] || fail "login shell is not executable: ${login_shell}"
login_tools="$(env PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  "${login_shell}" -lc 'for tool in nvim kitty tree-sitter mdview; do printf "__CONFIGS_TOOL__%s=%s\n" "$tool" "$(command -v "$tool" 2>/dev/null || true)"; done' \
  2>/dev/null || true)"
for tool in nvim kitty tree-sitter mdview; do
  login_path="$(printf '%s\n' "${login_tools}" | sed -n "s|^__CONFIGS_TOOL__${tool}=||p" | tail -n 1)"
  if [[ -z ${login_path} || $(realpath -m -- "${login_path}") != $(realpath -m -- "${local_bin}/${tool}") ]]; then
    fail "login shell does not select ${local_bin}/${tool}; add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to its startup file, open a new shell and rerun verify.sh"
  fi
done
printf '%s\n' 'VERIFY_OK: Nvim, Kitty, font, mdview, plugins, LSP and parsers are ready.'
