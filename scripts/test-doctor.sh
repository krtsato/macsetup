#!/usr/bin/env bash
# 点検の「壊して確かめる」検査。壊した所を名指しで検出し、失敗で終わることを確かめる。
# 何も変更しない。gh への読み取りの呼び出しは実際に行う。
set -euo pipefail

cd "$(dirname "$0")/.."

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

log() { echo "==> $*"; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-doctor.XXXXXX")"
trap 'rm -rf "${tmp}"' EXIT

passed=0
failed=0

# run_doctor <出力ファイル> <ansible-playbook の追加引数...>。終了コードを返す
run_doctor() {
  local out="$1"
  shift
  ansible-playbook -i ansible/hosts ansible/doctor.yaml "$@" </dev/null >"${out}" 2>&1
}

# expect_broken <名前> <出力ファイル> <終了コード> <出力に含まれるべき語>
expect_broken() {
  local name="$1" out="$2" rc="$3" needle="$4"
  if [ "${rc}" -ne 0 ] && grep -Fq -- "${needle}" "${out}"; then
    log "OK   ${name}: 失敗し、${needle} を名指しした"
    passed=$((passed + 1))
  else
    log "FAIL ${name}: rc=${rc}、出力に ${needle} が無い"
    tail -30 "${out}"
    failed=$((failed + 1))
  fi
}

# (a) 必須のファイルが 1 つ無い
log "(a) 必須のファイルが無い"
missing=".config/doctor-test-nonexistent/required.json"
rc=0
run_doctor "${tmp}/a.out" -e "$(printf '{"doctor_extra_config_files":[{"path":"%s","kind":"file","class":"auth","mode":"0600","required":true,"purpose":"test"}]}' "${missing}")" || rc=$?
expect_broken "missing required file" "${tmp}/a.out" "${rc}" "${missing}"

# (i) 秘密の場所がシンボリックリンク（参照先は 0600 の通常ファイル）
log "(i) 秘密の場所がシンボリックリンク"
linkdir="${HOME}/.config/doctor-test-symlink"
mkdir -p "${linkdir}"
: >"${tmp}/target.json"
chmod 600 "${tmp}/target.json"
ln -sf "${tmp}/target.json" "${linkdir}/linked.json"
rc=0
run_doctor "${tmp}/i.out" -e '{"doctor_extra_config_files":[{"path":".config/doctor-test-symlink/linked.json","kind":"file","class":"auth","mode":"0600","required":true,"purpose":"test"}]}' || rc=$?
rm -rf "${linkdir}"
expect_broken "symlinked secret" "${tmp}/i.out" "${rc}" ".config/doctor-test-symlink/linked.json: シンボリックリンク"

# (b) 存在しない複製のパス
log "(b) 存在しない複製のパス"
rc=0
run_doctor "${tmp}/b.out" -e '{"doctor_clone_dir_overrides":{"mcp-mediable/YOUTUBE_CLONE_DIR":"/nonexistent/doctor-test-clone"}}' || rc=$?
expect_broken "nonexistent clone path" "${tmp}/b.out" "${rc}" "mcp-mediable/YOUTUBE_CLONE_DIR"

# (c) SessionCreate=true にした plist の写し
log "(c) SessionCreate=true の plist"
mkdir "${tmp}/LaunchAgents"
cp "${HOME}"/Library/LaunchAgents/*.plist "${tmp}/LaunchAgents/"
plist="${tmp}/LaunchAgents/actions.runner.krtsato-mcp-mediable.mediable-sync-mac.plist"
plutil -replace SessionCreate -bool true "${plist}"
rc=0
run_doctor "${tmp}/c.out" -e "doctor_launchagents_dir=${tmp}/LaunchAgents" || rc=$?
expect_broken "SessionCreate=true plist" "${tmp}/c.out" "${rc}" "実行役 mcp-mediable/mediable-sync: plist の SessionCreate が false でない"

# (e) NOTEBOOKLM_PROFILE を読めないリポジトリ（存在しないリポジトリ）
log "(e) NOTEBOOKLM_PROFILE を読めない"
rc=0
run_doctor "${tmp}/e.out" -e '{"doctor_profile_repos":["mcp-note","doctor-test-nonexistent-repo"]}' || rc=$?
expect_broken "unreadable NOTEBOOKLM_PROFILE" "${tmp}/e.out" "${rc}" "doctor-test-nonexistent-repo/NOTEBOOKLM_PROFILE"

# 失敗の節・警告の節だけを取り出す（出力の msg 配列から）
section() { # section <出力ファイル> <失敗|警告>
  awk -v want="$2" '
    /--- 失敗 ---/ { cur = "失敗"; next }
    /--- 警告 ---/ { cur = "警告"; next }
    /^    \]/ { cur = "" }
    cur == want { print }' "$1"
}

# (f)(g) OpenD の境界。閉じたポートに向け、日本時間の「いま」を差し替える
log "(f) OpenD 土曜 00:30 は必須（失敗）"
rc=0
run_doctor "${tmp}/f.out" -e doctor_opend_port=1 -e doctor_now=2026-10-17T00:30 || rc=$?
if section "${tmp}/f.out" 失敗 | grep -Fq "OpenD 127.0.0.1:1"; then
  log "OK   Sat 00:30: OpenD が失敗の節にある"; passed=$((passed + 1))
else
  log "FAIL Sat 00:30: OpenD が失敗の節に無い"; failed=$((failed + 1))
fi

log "(g) OpenD 日曜 12:00 は警告のみ"
rc=0
run_doctor "${tmp}/g.out" -e doctor_opend_port=1 -e doctor_now=2026-10-18T12:00 || rc=$?
if section "${tmp}/g.out" 警告 | grep -Fq "OpenD 127.0.0.1:1" && ! section "${tmp}/g.out" 失敗 | grep -Fq "OpenD"; then
  log "OK   Sun 12:00: OpenD は警告の節だけにある"; passed=$((passed + 1))
else
  log "FAIL Sun 12:00: OpenD の扱いが期待と違う"; failed=$((failed + 1))
fi

# (h) profile 名が出力のどこにも出ないこと（-v の全出力）。名前は表示せず黙って比べる
log "(h) profile 名が出力へ漏れない"
leaks=0
checked=0
rc=0
run_doctor "${tmp}/h.out" -v || rc=$?
for repo in mcp-note mcp-seeking-alpha mcp-mediable; do
  value="$(gh variable get NOTEBOOKLM_PROFILE -R "krtsato/${repo}" 2>/dev/null || true)"
  [ -n "${value}" ] || continue
  checked=$((checked + 1))
  if grep -Fq -- "${value}" "${tmp}/h.out"; then leaks=$((leaks + 1)); fi
done
if [ "${checked}" -gt 0 ] && [ "${leaks}" -eq 0 ]; then
  log "OK   profile 名 ${checked} 件を -v の全出力で探して 0 件"; passed=$((passed + 1))
else
  log "FAIL profile 名の漏れ ${leaks} 件（確認した名前 ${checked} 件）"; failed=$((failed + 1))
fi

# 壊していない点検を 1 回。この端末に本物の失敗があるかを記録する
log "(d) 壊していない点検（この端末の実際の失敗と警告）"
rc=0
run_doctor "${tmp}/d.out" || rc=$?
echo "rc=${rc}"
sed -n '/Show the summary/,/Fail when/p' "${tmp}/d.out" | grep -E '^\s+"' || true

log "合格 ${passed} / 不合格 ${failed}"
[ "${failed}" -eq 0 ]
