#!/usr/bin/env bash
# runners 役割の検査。偽の gh・launchctl・config.sh・svc.sh を一時ディレクトリに置き、本物の登録鍵や
# 本物の実行役には一切触れずに確かめる。
# (a) 新規: 登録の引数・雛形と plist が SessionCreate=false・.path の先頭が shims・無効なら起動しない・鍵が出力に出ない
# (b) SHA-256 の不一致（と hash の欠落）は失敗し、展開しない
# (c) runners_enabled=true で起動は 1 回だけ（2 回目は呼ばない）
# (d) 登録済み（.runner あり）はダウンロードも登録もしない
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
# 役割は playbook と同じ場所から探されるので ansible/ に置く。名前は重ならないように作る
play="$(mktemp ansible/_test_runners.XXXXXX)"
trap 'rm -rf "${tmp}" "${play}"' EXIT
printf -- '- hosts: default\n  connection: local\n  gather_facts: false\n  roles:\n    - runners\n' >"${play}"
passed=0 failed=0 rc=0 out=""
token="FAKE-TOKEN-123"
fake="${tmp}/fakebin"
mkdir -p "${fake}"

# --- 偽の gh: 呼ばれた引数を calls.log に残す。鍵は固定の偽物 ---
cat >"${fake}/gh" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
echo "$*" >>"${d}/gh-calls.log"
case "$*" in
  "api repos/actions/runner/releases/latest") cat "${d}/release.json" ;;
  "api -X POST repos/krtsato/"*"/actions/runners/registration-token --jq .token") echo "FAKE-TOKEN-123" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
EOF
# --- 偽の launchctl: bootstrap を記録し、bootstrap 済みの label だけ print が成功する ---
cat >"${fake}/launchctl" <<'EOF'
#!/bin/bash
d="$(dirname "$0")"
echo "$*" >>"${d}/launchctl-calls.log"
case "$1" in
  print) grep -qx "${2##*/}" "${d}/loaded" 2>/dev/null ;;
  bootstrap) basename "$3" .plist >>"${d}/loaded" ;;
  *) echo "unexpected launchctl call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "${fake}/gh" "${fake}/launchctl"
# 偽物が本当に先に見つかるかを、役割と同じ PATH で確かめる。外れたら本物の launchctl が
# この Mac の LaunchAgent を操作しうるので、何も流さずに止める
for cmd in gh launchctl; do
  got="$(PATH="${fake}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" command -v "${cmd}")"
  if [ "${got}" != "${fake}/${cmd}" ]; then
    echo "==> 中止: ${cmd} が偽物でなく ${got} に解決される" >&2
    exit 1
  fi
done

# --- 偽の配布物: config.sh が .runner・svc.sh・.service を作る（本物と同じ流れ） ---
src="${tmp}/src"
mkdir -p "${src}/bin"
cat >"${src}/bin/actions.runner.plist.template" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>{{SvcName}}</string>
    <key>SessionCreate</key>
    <true/>
  </dict>
</plist>
EOF
cat >"${src}/config.sh" <<'EOF'
#!/bin/bash
echo "$*" >>./config.args
name=""
while [ $# -gt 0 ]; do [ "$1" = "--name" ] && name="$2"; shift; done
repo="$(pwd | sed 's:.*/::')"
echo '{}' >.runner
cat >svc.sh <<SVC
#!/bin/bash
SVC_NAME="actions.runner.krtsato-${repo}.${name}"
plist="\${HOME}/Library/LaunchAgents/\${SVC_NAME}.plist"
echo "install" >>./svc.log
mkdir -p "\${HOME}/Library/LaunchAgents"
sed "s/{{SvcName}}/\${SVC_NAME}/" ./bin/actions.runner.plist.template >"\${plist}"
echo "\${plist}" >.service
SVC
chmod +x svc.sh
EOF
chmod +x "${src}/config.sh"
tar -czf "${tmp}/runner.tar.gz" -C "${src}" .
sha="$(shasum -a 256 "${tmp}/runner.tar.gz" | cut -d' ' -f1)"
release() { # release <sha を入れる本文>
  jq -n --arg url "file://${tmp}/runner.tar.gz" --arg body "$1" \
    '{tag_name:"v9.9.9",body:$body,assets:[{name:"actions-runner-osx-arm64-9.9.9.tar.gz",browser_download_url:$url}]}' >"${fake}/release.json"
}
good_body="- actions-runner-osx-arm64-9.9.9.tar.gz <!-- BEGIN SHA osx-arm64 -->${sha}<!-- END SHA osx-arm64 -->"

reset() { # reset <home 名>。偽の記録と home を初期化する
  rm -rf "${tmp:?}/$1" "${fake}/gh-calls.log" "${fake}/launchctl-calls.log" "${fake}/loaded"
  mkdir -p "${tmp}/$1"
  touch "${fake}/gh-calls.log" "${fake}/launchctl-calls.log" "${fake}/loaded"
}
run() { # run <home 名> <有効 true|false> [ansible の追加引数]。出力は out、終了コードは rc
  local h="$1" en="$2"
  shift 2
  rc=0
  out="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ansible-playbook -i ansible/hosts "${play}" \
    -e "runners_home=${tmp}/${h}" -e "runners_path_prefix=${fake}" -e runners_name_suffix=testhost \
    -e "runners_enabled=${en}" \
    -e '{"runners_list":[{"repo":"fakerepo","label":"fakelabel","dir":"runner"}]}' "$@" </dev/null 2>&1)" || rc=$?
}
ok() { echo "==> PASS $1"; passed=$((passed + 1)); }
ng() { echo "==> FAIL $1"; [ -z "${2:-}" ] || tail -15 <<<"${out}"; failed=$((failed + 1)); }
check() { # check <名前> <期待する終了 ok|fail> <期待する文字列>
  local good=0
  if [ "$2" = ok ]; then [ "${rc}" -eq 0 ] && good=1; else [ "${rc}" -ne 0 ] && good=1; fi
  if [ "${good}" = 1 ] && grep -q -- "$3" <<<"${out}"; then ok "$1"; else ng "$1（rc=${rc}）" 1; fi
}
assert() { # assert <名前> <条件を表すコマンド...>
  local name="$1"
  shift
  if "$@"; then ok "${name}"; else ng "${name}"; fi
}
session() { plutil -extract SessionCreate raw -o - "$1"; }
count() { grep -c -- "$1" "$2" || true; }

# (a) 新規・無効
reset home; release "${good_body}"
dir="${tmp}/home/runner"
plist="${tmp}/home/Library/LaunchAgents/actions.runner.krtsato-runner.fakelabel-testhost.plist"
run home false -vvv; check "(a) 新規の登録" ok "failed=0"
assert "(a) 登録の引数" grep -qx -- "--unattended --url https://github.com/krtsato/fakerepo --token ${token} --name fakelabel-testhost --labels fakelabel --work _work" "${dir}/config.args"
assert "(a) --replace を使わない" bash -c "! grep -q -- --replace '${dir}/config.args'"
no_token() { [ -n "${out}" ] && ! grep -q -- "${token}" <<<"${out}"; }
assert "(a) 鍵が ansible の出力に出ない（-vvv）" no_token
assert "(a) 雛形が SessionCreate=false" test "$(session "${dir}/bin/actions.runner.plist.template")" = false
assert "(a) plist が SessionCreate=false" test "$(session "${plist}")" = false
assert "(a) .path の先頭が shims" bash -c "[ \"\$(cut -d: -f1 '${dir}/.path')\" = '${tmp}/home/.local/share/mise/shims' ]"
assert "(a) 無効なら起動しない" bash -c "! grep -q bootstrap '${fake}/launchctl-calls.log'"
run home false; check "(a) 2 回目は何もしない" ok "changed=0"
assert "(a) 2 回目は登録も取得もしない" test "$(count 'registration-token' "${fake}/gh-calls.log")" = 1

# (b) SHA-256 の不一致・hash の欠落
reset hb; release "- actions-runner-osx-arm64-9.9.9.tar.gz <!-- BEGIN SHA osx-arm64 -->$(printf '0%.0s' {1..64})<!-- END SHA osx-arm64 -->"
run hb false; check "(b) SHA-256 の不一致は失敗" fail "SHA-256 が一致しない"
assert "(b) 展開しない" bash -c "[ ! -e '${tmp}/hb/runner/config.sh' ]"
assert "(b) 登録鍵を取らない" bash -c "! grep -q registration-token '${fake}/gh-calls.log'"
reset hb; release "- no hash published"
run hb false; check "(b) hash の欠落は失敗" fail "SHA-256 が無い"
assert "(b) 欠落でも展開しない" bash -c "[ ! -e '${tmp}/hb/runner/config.sh' ]"

# (c) 有効: 起動は 1 回だけ
reset hc; release "${good_body}"
run hc true; check "(c) 有効なら起動" ok "failed=0"
assert "(c) bootstrap は 1 回" test "$(count bootstrap "${fake}/launchctl-calls.log")" = 1
run hc true; check "(c) 2 回目は何もしない" ok "changed=0"
assert "(c) 2 回目は bootstrap しない" test "$(count bootstrap "${fake}/launchctl-calls.log")" = 1

# (d) 登録済み（この Mac の形）: 取得も登録もしない。雛形と .path だけ直す。既存の plist は書き換えない
reset hd; release "${good_body}"
d="${tmp}/hd/runner"
mkdir -p "${d}/bin" "${tmp}/hd/Library/LaunchAgents"
cp "${src}/bin/actions.runner.plist.template" "${d}/bin/"
echo '{}' >"${d}/.runner"
echo 'actions.runner.krtsato-runner.old-mac' >"${d}/.service"
printf '#!/bin/bash\nSVC_NAME="actions.runner.krtsato-runner.old-mac"\necho svc-called >>./svc.log\n' >"${d}/svc.sh"
chmod +x "${d}/svc.sh"
sed 's/<true\/>/<false\/>/' "${src}/bin/actions.runner.plist.template" >"${tmp}/hd/Library/LaunchAgents/actions.runner.krtsato-runner.old-mac.plist"
before="$(shasum "${tmp}/hd/Library/LaunchAgents/actions.runner.krtsato-runner.old-mac.plist")"
printf '/usr/bin:/bin' >"${d}/.path"
run hd false; check "(d) 登録済みは成功" ok "failed=0"
assert "(d) gh を一度も呼ばない" test ! -s "${fake}/gh-calls.log"
assert "(d) svc.sh install を呼ばない" test ! -e "${d}/svc.log"
assert "(d) 既存の plist はそのまま" test "$(shasum "${tmp}/hd/Library/LaunchAgents/actions.runner.krtsato-runner.old-mac.plist")" = "${before}"
assert "(d) 雛形は false になる" test "$(session "${d}/bin/actions.runner.plist.template")" = false
assert "(d) .path は残りを保って先頭に shims" test "$(cat "${d}/.path")" = "${tmp}/hd/.local/share/mise/shims:/usr/bin:/bin"
run hd false; check "(d) 2 回目は何もしない" ok "changed=0"

echo "==> 合格 ${passed} / 不合格 ${failed}"
[ "${failed}" -eq 0 ]
