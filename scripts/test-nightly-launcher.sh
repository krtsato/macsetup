#!/usr/bin/env bash
# nightly_launcher 役割の読み込み規則の検査。偽の launchctl と、一時の bare リポジトリから作った
# watcher の複製（plan.json だけを持つ）を使い、この Mac の LaunchAgent には一切触れない。
# (i) 無効・未読み込み: plist は作るが bootstrap しない
# (ii) 有効・未読み込み: 枠ごとに 1 回 bootstrap し、2 回目は呼ばない（bootout は読み込み前に毎回 1 回走る既存の動き）
# (iii) 無効でも既に読み込み済み・plist が同じ: bootout も bootstrap もしない
# (iv) 無効でも既に読み込み済み・plan.json の時刻を変えた枠だけ: bootout ＋ bootstrap で読み直す
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
play="$(mktemp ansible/_test_nightly.XXXXXX)"
trap 'rm -rf "${tmp}" "${play}"' EXIT
printf -- '- hosts: default\n  connection: local\n  gather_facts: false\n  roles:\n    - nightly_launcher\n' >"${play}"
passed=0 failed=0 rc=0 out=""
fake="${tmp}/fakebin"
mkdir -p "${fake}"
cat >"${fake}/launchctl" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
echo "$1" >>"${d}/launchctl-calls.log"
case "$1" in
  print) grep -qx "${2##*/}" "${d}/loaded" 2>/dev/null ;;
  bootstrap) basename "$3" .plist >>"${d}/loaded" ;;
  bootout) grep -vx "${2##*/}" "${d}/loaded" >"${d}/loaded.new" || true; mv "${d}/loaded.new" "${d}/loaded" ;;
  *) echo "unexpected launchctl call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${fake}/launchctl"
# 偽物が先に見つかることを、役割と同じ PATH で確かめる。外れたら何も流さずに止める
got="$(PATH="${fake}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" command -v launchctl)"
if [ "${got}" != "${fake}/launchctl" ]; then
  echo "==> 中止: launchctl が偽物でなく ${got} に解決される" >&2
  exit 1
fi

home="${tmp}/home"
bare="${tmp}/watcher.git"
work="${tmp}/work"
plan() { # plan <A の時刻>
  printf '{"slots":[{"name":"A","at":"%s"},{"name":"B","at":"06:30"}]}\n' "$1"
}
git init -q --bare -b main "${bare}"
git clone -q "${bare}" "${work}" 2>/dev/null
git -C "${work}" config user.email t@example.invalid
git -C "${work}" config user.name test
mkdir -p "${work}/cmd/nightly-launcher"
plan 01:30 >"${work}/cmd/nightly-launcher/plan.json"
git -C "${work}" add -A && git -C "${work}" commit -q -m plan && git -C "${work}" push -q origin HEAD:main
git clone -q "${bare}" "${tmp}/watcher"

reset() { rm -rf "${home}" "${fake}/launchctl-calls.log" "${fake}/loaded"; mkdir -p "${home}"; touch "${fake}/launchctl-calls.log" "${fake}/loaded"; }
run() { # run <有効 true|false>
  rc=0
  out="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ansible-playbook -i ansible/hosts "${play}" \
    -e "nightly_launcher_home=${home}" -e "nightly_launcher_repo=${tmp}/watcher" \
    -e "nightly_launcher_path_prefix=${fake}" -e "nightly_launcher_enabled=$1" </dev/null 2>&1)" || rc=$?
}
ok() { echo "==> PASS $1"; passed=$((passed + 1)); }
ng() { echo "==> FAIL $1"; tail -12 <<<"${out}"; failed=$((failed + 1)); }
calls() { grep -c -x -- "$1" "${fake}/launchctl-calls.log" || true; }
expect() { # expect <名前> <bootstrap 回数> <bootout 回数>
  if [ "${rc}" -eq 0 ] && [ "$(calls bootstrap)" = "$2" ] && [ "$(calls bootout)" = "$3" ]; then
    ok "$1"
  else
    echo "（rc=${rc} bootstrap=$(calls bootstrap) bootout=$(calls bootout)、期待 $2/$3）"; ng "$1"
  fi
}
plist="${home}/Library/LaunchAgents/com.krtsato.watcher.nightly-launcher"

# (i)
reset; run false
expect "(i) 無効・未読み込みは起動しない" 0 0
if [ -f "${plist}.A.plist" ] && [ -f "${plist}.B.plist" ]; then ok "(i) plist は作る"; else ng "(i) plist は作る"; fi
# (ii)
reset; run true
expect "(ii) 有効なら枠ごとに 1 回" 2 2
run true
expect "(ii) 2 回目は呼ばない" 2 2
# (iii)（(ii) の状態から無効で流す）
run false
expect "(iii) 読み込み済み・変更なしは何もしない" 2 2
# (iv) A の時刻だけ変える
sed -i.bak 's/01:30/02:00/' "${work}/cmd/nightly-launcher/plan.json" && rm "${work}/cmd/nightly-launcher/plan.json.bak"
git -C "${work}" commit -q -am "plan: A 02:00" && git -C "${work}" push -q origin HEAD:main
run false
expect "(iv) 変えた枠だけ読み直す" 3 3
if grep -q '<integer>2</integer>' "${plist}.A.plist"; then ok "(iv) plist の時刻が変わる"; else ng "(iv) plist の時刻が変わる"; fi
echo "==> 合格 ${passed} / 不合格 ${failed}"
[ "${failed}" -eq 0 ]
