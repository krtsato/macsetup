# 切り替えの手順書 — 旧い Mac から新しい Mac へ夜間の自動実行を移す

**旧い Mac を止めて空になったことを確かめてから、新しい Mac を動かす。** これが要点です。
旧と新が同じ夜に仕事を取ると、同じ処理が 2 回走り、変更要求や記録が重複します。
名前を変えても二重実行は防げません（同じ用途の実行役が 2 体とも待機中なら GitHub は任意の 1 体へ割り当てる）。
防げるのはこの手順の**順序**だけです。

| 項目 | 内容 |
| --- | --- |
| 対象 | 自前の実行役 5 体・夜間の起動役 2 本（01:30 と 06:30 の枠）・moomoo の接続役・各種ログイン・処理済みの記録 |
| 前提 | 段 1〜5 が入った macsetup が**旧い Mac にも新しい Mac にも**ある（`git pull` 済み） |
| 所要 | 作業は半日。完了の確認は曜日限定の仕事があるので**通常 1 週間** |
| 戻せる範囲 | 手順 14（旧い登録の削除）より前なら戻せる。「戻し方」を参照 |
| 親の課題 | `krtsato/macsetup` の #10（計画の全文）・#16（この段） |

以下、**旧端末**は今夜間の仕事をしている Mac、**新端末**は買い替えた Mac です。

## 手順の一覧

| 順 | やること | 誰が |
| --- | --- | --- |
| 1 | 新端末で `make setup`（実行役と起動役は**停止した状態**）。途中の `gh` ログインと SSH 鍵の登録まで進む | 人＋自動 |
| 2 | 新端末で Claude にログインする | 人 |
| 3 | Docker Desktop の初回設定、OpenD の導入とログイン、自動ログイン、再起動 | 人 |
| 4 | 新端末で `make doctor PHASE=pre-import` | 自動 |
| 5 | **夜間の枠の外で**、旧端末が空であることを確かめる | 自動 |
| 6 | 旧端末の起動役 2 本を無効にする | 人 |
| 7 | **無効にした後で改めて**、旧端末が空であることを確かめる | 自動 |
| 8 | 旧端末の実行役 5 体を止め、GitHub 上で offline を確認する | 人＋自動 |
| 9 | 旧端末で `make secrets-export` → 新端末で `make secrets-import` | 人＋自動 |
| 10 | 新端末で `make doctor PHASE=cutover`。**足りない物だけ**ログインし直す | 人 |
| 11 | 新端末の実行役を起動し、online・ラベル・PATH・`SessionCreate=false` を確認する | 自動 |
| 12 | 新端末の起動役を起動し、`make doctor`（稼働の段階）を通す | 自動 |
| 13 | 試し実行（`make cutover-trial` が出す、副作用のないものだけ）を起動する | 自動 |
| 14 | 完了の一覧 21 単位が新端末で成功したら、旧端末の実行役の登録を GitHub から消す | 人 |

## 準備

| 道具 | 使いどころ |
| --- | --- |
| `gh` | 旧端末・新端末の両方でログイン済み（`gh auth status`）。管理者権限があること |
| `jq` | 確認用のコマンドで使う |
| 夜間の枠 | 01:30〜06:25（枠 A）と 06:30〜08:30（枠 B）、日本時間。枠は最大 1 時間遅れて始まることがある |

以降のコマンドで使う変数です。どの端末のシェルでも、先に貼っておきます。

```sh
REPOS="mcp-invest-knowledge mcp-tradingview mcp-mediable mcp-note mcp-seeking-alpha"
```

## 手順 1〜4 — 新端末を停止した状態で組み立てる

**まだ旧端末には触りません。** 新端末の実行役と起動役は登録だけして起動しないので、旧端末と競合しません。

### 手順 1 — `make setup`

```sh
cd ~/dev/me/macsetup
make setup ANSIBLE_FLAGS='--ask-become-pass'
```

- `runners_enabled` と `nightly_launcher_enabled` は既定が `false`。**何も指定しなければ起動しません**
- 途中の `github` 役割が `gh` のログインを待ちます。表示に従ってブラウザで認証し、SSH 鍵の作成・登録まで進めます
  （手で行うなら `gh auth login -h github.com -s admin:public_key`）
- 実行役の名前は `<用途>-<端末名>`（例: `knowledge-sync-<端末名>`）で、旧端末の名前と重なりません

### 手順 2 — Claude にログイン

**持ち込みの対象外**（キーチェーンにあり、ファイルとして運べない）ので、手でログインします。

```sh
claude auth login
claude auth status
```

### 手順 3 — Docker・接続役・自動ログイン

| 項目 | やること |
| --- | --- |
| Docker Desktop | 起動して初回の同意を済ませる。Settings → Resources → Network → **Enable host networking** を有効にする（moomoo のコンテナが OpenD に届くため）。その後 `make playbook` を流し直すと moomoo 用の image が作られる |
| OpenD | <https://www.moomoo.com/download/OpenAPI> から GUI 版を入れる。ログインと二段階認証を済ませ、待受を `127.0.0.1`・ポート `11111` にし、**ログイン項目に登録**する（再起動後も火〜土の夜間に要る） |
| 自動ログイン | 有効にする。再起動後もキーチェーンが開いた状態にしておく（著述系が Claude のログインを読むため） |
| 再起動 | **登録後に 1 回再起動**して、OpenD が自動で立ち上がることを確かめる |

```sh
make playbook ANSIBLE_FLAGS='--ask-become-pass'   # Docker の設定後。moomoo の image を作る
nc -z 127.0.0.1 11111 && echo "OpenD 待受あり"      # 再起動後に確認
```

**ここで codex と NotebookLM にはログインしないでください。** 手順 9 の持ち込みと衝突します。

### 手順 4 — 持ち込み前の点検

```sh
make doctor PHASE=pre-import
```

失敗が 0 件になるまで直します。この段階では「持ち込む秘密と記録・codex と NotebookLM のログインが**無いこと**」を期待します
（あれば衝突の警告が出ます）。

## 手順 5〜8 — 旧端末を止めて、空になったことを確かめる

### 手順 5 — 夜間の枠の外で、旧端末が空か確かめる

**夜間の枠（01:30〜08:30 の日本時間）の外で行います**（目安は 10:00〜24:00）。枠の途中で止めると、
走りかけの仕事を切ることになります。次の 4 つを**旧端末**（または `gh` が使える任意の端末）で確かめます。

```sh
# (1) 起動役が動いていない（process が無い）
pgrep -fl nightly-launcher || echo "起動役の process なし"

# (2) 実行役が仕事中でない（busy が 1 件も出ない）
for r in $REPOS; do
  gh api "repos/krtsato/$r/actions/runners" --jq '.runners[] | select(.busy) | "仕事中: \(.name)"'
done

# (3) 実行中・待機中の仕事が 0
for r in $REPOS; do
  for s in in_progress queued waiting requested pending; do
    n="$(gh run list -R "krtsato/$r" --status "$s" --json databaseId --jq length)"
    [ "$n" = 0 ] || echo "$r: $s が $n 件"
  done
done

# (4) 起動役の再開記録がすべて完了済み（何も出なければよい）
for f in ~/dev/me/watcher/.launcher/state-*.json; do
  [ -e "$f" ] || continue
  jq -r 'select((.done | not) and ((.runs | length) > 0)) | "未完了: \(.slot) \(.date)"' "$f"
done
```

**何か出たら先へ進みません。** 仕事が終わるのを待ち、もう一度確かめます。

### 手順 6 — 旧端末の起動役 2 本を無効にする

```sh
for slot in A B; do
  launchctl bootout "gui/$(id -u)/com.krtsato.watcher.nightly-launcher.$slot" 2>/dev/null || true
done
launchctl print "gui/$(id -u)/com.krtsato.watcher.nightly-launcher.A" 2>&1 | head -1   # 「Could not find service」ならよい
launchctl print "gui/$(id -u)/com.krtsato.watcher.nightly-launcher.B" 2>&1 | head -1
```

plist のファイルは消しません（戻すとき `bootstrap` し直すだけで済むように残します）。

### 手順 7 — 無効にした後で、改めて確かめる

**手順 5 の 4 つを、そのままもう一度実行します。** 直前の確認と無効化の間に入った仕事を拾うためです。
実行中・待機中が 0、実行役が仕事中でない、再開記録がすべて完了済み、の 3 点が揃うまで先へ進みません。

### 手順 8 — 旧端末の実行役 5 体を止める

```sh
for p in ~/Library/LaunchAgents/actions.runner.*.plist; do
  case "$p" in *.bak) continue ;; esac
  launchctl bootout "gui/$(id -u)" "$p" 2>/dev/null || true
done
pgrep -fl Runner.Listener || echo "Runner.Listener の process なし"
```

GitHub 上で offline になったことを確かめます（**登録は消しません**。消すのは手順 14）。

```sh
for r in $REPOS; do
  gh api "repos/krtsato/$r/actions/runners" --jq '.runners[] | "\(.name)\t\(.status)"'
done
```

旧端末の名前がすべて `offline` で、新端末の名前（停止中）も `offline` のはずです。`online` が残っていれば止まっていません。

## 手順 9〜10 — 記録を写してログインを足す

### 手順 9 — 秘密と処理済みの記録を運ぶ

**対話の端末で行います**（Ansible や CI からは不可。合言葉は `hdiutil` が端末で尋ねます）。

旧端末:

```sh
cd ~/dev/me/macsetup
make secrets-list                                              # 運ぶ物と、実行役・起動役が止まっていることを表示
make secrets-export OUT=$HOME/Desktop/macsetup-secrets.dmg     # OUT はリポジトリの外の絶対パス
```

新端末（イメージを USB などで運んだ後）:

```sh
cd ~/dev/me/macsetup
make secrets-import IMAGE=/Volumes/USB/macsetup-secrets.dmg
```

- `export` は**実行役と起動役が止まっていないと拒否**します（確かめられなければ止まっているとみなしません）
- `import` は衝突が 1 件でもあれば何も変えずに止まります。途中で失敗したら配置前に戻ります
- 強制終了などで跡が残ったら `make secrets-recover`
- **イメージは作業後に消します**（中身は秘密です。公開リポジトリには絶対に置かない）

### 手順 10 — 切り替え中の点検と、足りないログイン

```sh
make doctor PHASE=cutover
```

`import` の最後にも流れますが、ここで改めて確認します。**名指しされた物だけ**ログインし直します。

| 足りない物 | やること |
| --- | --- |
| `codex` | `codex login` |
| NotebookLM | 持ち込みで入るのが普通。足りなければ `nlm login --profile "$(gh variable get NOTEBOOKLM_PROFILE -R krtsato/mcp-note)"`（プロファイル名はアカウントの識別子に近いので、画面や記録に残さない） |
| moomoo の接続役 | OpenD を起動してログイン、二段階認証 |

失敗が 0 件になるまで直します。

## 手順 11〜13 — 新端末を動かす

### 手順 11 — 実行役を起動する

**旧端末が空になったことを確かめた後にだけ**実行します（手順 5〜8 が済んでいること）。

```sh
make playbook EXTRA_VARS='runners_enabled=true'
```

起動したものは、GitHub 上で online になるまで待ってから成功になります（既定 120 秒。来なければ名前つきで失敗）。
次を確かめます。

```sh
for r in $REPOS; do
  gh api "repos/krtsato/$r/actions/runners" --jq '.runners[] | "\(.name)\t\(.status)\t\([.labels[].name] | join(","))"'
done
for p in ~/Library/LaunchAgents/actions.runner.*.plist; do
  case "$p" in *.bak) continue ;; esac
  echo "$(basename "$p"): SessionCreate=$(plutil -extract SessionCreate raw "$p")"   # false であること
done
```

| 確認 | 期待 |
| --- | --- |
| 状態 | 新端末の 5 体が `online` |
| ラベル | `self-hosted,macOS,ARM64` と用途のラベル |
| `SessionCreate` | 5 体とも `false`（`true` だと Claude がキーチェーンを読めず、著述系が落ちる） |
| `.path` | 先頭が mise の shims（`make doctor` が見る） |

### 手順 12 — 起動役を起動し、稼働の点検を通す

```sh
make playbook EXTRA_VARS='runners_enabled=true nightly_launcher_enabled=true'
make doctor
```

- 実行役がすでに動いていれば触りません（冪等）
- `make doctor`（稼働の段階）は、実行役が online・起動役が読み込み済み・OpenD が開いている、を期待します
- OpenD は**日本時間の土曜 01:30〜月曜 01:30 以外**で閉じていると失敗します

### 手順 13 — 試し実行

**全ワークフローを手で起動してはいけません。** 変更要求を作る・状態を書き換える・証券口座の一覧に反映する副作用があります。
副作用のないものだけを、次の命令で確かめます。この命令は**コマンドを出すだけで起動しません**
（手元の複製を `git fetch origin main`（読むだけ）してから、**GitHub の main** のワークフロー定義を読んで作ります。
作業ツリーが別の branch や未 commit でも影響しません。複製が無い・fetch できない・`.github/workflows` が無いときは、名前を出して失敗します）。

```sh
make cutover-trial
```

出力は 2 つの節に分かれます。

| 節 | 中身 |
| --- | --- |
| 試し実行 | `gh workflow run <ファイル> -R krtsato/<リポジトリ> -f dry_run=true ...` の形。**入力値まで**書いてある（入力を省くと実際に書き込む） |
| 夜間の実行で確かめる | 試し実行にできないもの（理由つき）。夜間の本番の成功で確かめる |

出た行を 1 本ずつ実行し、成功を確かめます。例:

```sh
gh workflow run nikkei-eps-sync.yaml -R krtsato/mcp-tradingview -f dry_run=true
gh run list -R krtsato/mcp-tradingview --workflow nikkei-eps-sync.yaml -L 1
gh api repos/krtsato/mcp-tradingview/actions/runs/<run の番号>/jobs --jq '.jobs[].runner_name'   # 新端末の名前であること
```

試し実行の入力値は、各ワークフローの定義を 1 本ずつ読み、どの手順を止めるかを確かめて決めたものです。

| 種類 | 入力 | 備考 |
| --- | --- | --- |
| `dry_run` がある（下の除外を除く） | `dry_run=true`（あれば `skip_audio=true`・`audio_dry_run=true`・件数を 1） | 変更要求・コミット・送信を止める。取得と検証は本物なので、**ログインや接続の確認になる** |
| 入力が無く、**全 job の権限が明示的に読み取りだけ** | 入力なし | 検査だけのワークフロー（`digest-check`・`note-check`・`watchlist-check`）。**`permissions` を省略したものは対象外**（省略すると既定の権限になり、書き込めることがある） |
| 夜間で確かめる | — | 下の表 |

今の内訳は**試し実行 11 本・夜間で確かめる 7 本**です（`make cutover-trial` の出力が正本）。

夜間で確かめるもの（`make cutover-trial` の出力が正本です）:

| ワークフロー | 試し実行にしない理由 |
| --- | --- |
| `undigested-captions`・`digest-corpus-audit` | 入力が無く、実行すると追跡用の課題を更新する |
| `digest-author` | `dry_run` でも、保留になった下書きを手元の保管場所へ書く。LLM の使用量も消費する |
| `note-author` | `dry_run` でも Claude と Codex を呼び（使用量を消費）、作業の跡を書く。PR を作らないだけ |
| `daily-magazine-sync`（mcp-note） | `dry_run` でも Docker の image を作り、最後に `docker system prune --force` を実行する |
| `daily-mediable-sync` | `dry_run` でも最後の手順が downloads の削除と Docker の掃除（`make docker-prune`）を実行する |
| `ledger-sync` | `dry_run` でも走査の本体が最後まで動く（最大 280 分・TradingView へ大量に問い合わせる） |

注意:

- `watchlist-sync` の試し実行は、TradingView と moomoo への**送信を止める**ので、OpenD の疎通の証拠にはなりません
- note・mediable・`note-author` は夜間の本番でしか確かめられません。ログインの不足は `make doctor` と夜間の結果で見ます
- 試し実行の成功は、手順 14 の完了の数に**入れません**（下の「完了の確認」を参照）

## 手順 14 — 完了の確認と旧い登録の削除

### 完了の一覧

**21 単位**です。起動役の予定表（`krtsato/watcher` の `cmd/nightly-launcher/plan.json`）の **18 の仕事**と、
予定表に無い自前実行のワークフロー **3 本**（`digest-check`・`note-check`・`watchlist-check`）を合わせたものです。
一覧は実行時に予定表と各ワークフローから作ります（書き写しません）。

各単位が、**新端末の実行役で 1 回成功**したら完了です（**全ページの job** の `runner_name` が新端末の実行役であることまで見ます。`runner_name` が空の job・旧端末の job が 1 つでもあれば数えません）。
曜日限定の仕事は、その曜日（日本時間）に走るまで未完了のままです（火曜 2 本・土曜 1 本・火〜土 5 本）。
通常 **1 週間**かかります。

### 判定の命令

```sh
make cutover-check SINCE=<YYYY-MM-DD> RUNNERS=<新端末の実行役の名前、またはその末尾>
```

| 引数 | 意味 |
| --- | --- |
| `SINCE` | 数え始める日。`YYYY-MM-DD` は日本時間のその日の 0 時。**試し実行の翌日**にする（試し実行を数えないため） |
| `RUNNERS` | 新端末の実行役。名前をカンマ区切りで並べるか、名前の末尾（`<端末名>` を書くと `*-<端末名>` が全部一致） |

例（新端末の端末名が `newmac` で、試し実行が 10 月 14 日だったとき）:

```sh
make cutover-check SINCE=2026-10-15 RUNNERS=newmac
```

出力は単位ごとの表（状態・単位・run の URL または理由）と、最後の集計 `done N / pending M / 合計 21` です。
**pending が 1 つでもあれば 0 以外で終わります**（make 経由では 2）。全部 `done` になって 0 で終わるまで、毎日 1 回など繰り返します。

| pending の理由 | 意味と次の手 |
| --- | --- |
| `SINCE 以降の成功なし` | まだ走っていない、または失敗した。夜間の結果と見張りの通知を見る |
| `成功は N 回あるが、新端末の実行役ではない` | 旧端末が取った。旧端末の実行役が止まっていない（手順 8 をやり直す） |
| `対象の曜日（…）がまだ来ていない（次: 日付）` | 待つ |
| `新端末の成功は N 回あるが、対象の曜日（…）のものが無い` | 手動の run が曜日の外で成功しただけ。対象の曜日の夜を待つ |

### 同じワークフローを複数の単位が使うときの数え方

起動役の予定表には、同じワークフローを 1 晩に複数回起こす仕事があります
（`turnover-snapshot` が 3 つ・`daily-mediable-sync` が 2 つ）。GitHub の run には**入力も仕事の ID も残らない**ので、
どの run がどの単位かは 1 本ずつ対応づけられません。そこで**1 晩ぶんをまとめて**判定します。

| 条件（すべて満たす晩が 1 つあれば、そのワークフローの全単位が `done`） | 理由 |
| --- | --- |
| 同じ日付（日本時間）の、各枠の `at`〜`deadline` の窓の中に、**枠ごとの単位数ぶん以上**の新端末での成功がある | `turnover-snapshot` は枠 A に 1・枠 B に 2 |
| その窓の中に、**失敗・取り消し・時間切れの run が 1 つも無い** | 失敗した単位があるのに、別の成功で埋まって見えるのを防ぐ |
| 単位の曜日が、その晩の曜日に合う | 曜日限定の単位がある場合 |

- 起動役は 1 晩に各単位を 1 回ずつ起こすので、**その晩が丸ごと成功なら各単位が成功している**と言えます
- 別々の晩の成功は足しません（片方の単位が毎晩失敗していても、別の晩の成功で埋まらないようにするため）
- 表の `共有 k/N` は、その晩までに満たした数 k と、要る数 N です。満たさない理由は行に出ます
- 窓の中の手動の run も数えてしまいます。試し実行は窓の外（昼）に行い、SINCE を試し実行の翌日にしてください

### 旧い登録の削除

**`make cutover-check` が全部 `done`（終了コード 0）になってから**行います。ここから先は戻せません。

まず、削除の候補を**読むだけ**で確かめます（新端末の名前で終わらないものが旧端末の登録です）。

```sh
NEW_SUFFIX="$(scutil --get LocalHostName)"
for r in $REPOS; do
  gh api "repos/krtsato/$r/actions/runners" \
    --jq ".runners[] | select(.name | endswith(\"-$NEW_SUFFIX\") | not) | \"$r\t\(.id)\t\(.name)\t\(.status)\""
done
```

出た行が**旧端末の 5 体**で、すべて `offline` であることを目で確かめてから、1 体ずつ消します。

```sh
gh api -X DELETE "repos/krtsato/<リポジトリ>/actions/runners/<上の表の id>"
```

消した後、`make doctor` が通ることと、翌朝の夜間の実行が新端末で成功することを確かめて完了です。

## 戻し方

**手順 14 の削除より前なら戻せます。** 旧端末の登録がまだ GitHub に残っているためです。
**通常の切り替えと同じ安全な順序**で行います。**走っている仕事を切ってはいけません**
（夜間の枠の外で行い、新端末の起動役を先に止めて、空になったことを確かめてから実行役を止めます）。

| 順 | 端末 | やること |
| --- | --- | --- |
| 1 | 新端末 | 起動役 2 本を無効にする（手順 6 と同じ `launchctl bootout`） |
| 2 | 新端末 | 手順 5 の 4 つの確認を行う（起動役の process なし・実行役が仕事中でない・実行中と待機中が 0・再開記録がすべて完了済み。`.launcher` は新端末の `~/dev/me/watcher` を見る） |
| 3 | 新端末 | **無効にした後で、もう一度**同じ 4 つを確認する（直前の確認と無効化の間に入った仕事を拾うため） |
| 4 | 新端末 | 実行役 5 体を止め、GitHub 上で offline を確認する（手順 8 と同じ） |
| 5 | 新端末 | `make secrets-export OUT=$HOME/Desktop/macsetup-rollback.dmg`（止まっていないと拒否される） |
| 6 | 旧端末 | `make secrets-restore IMAGE=/Volumes/USB/macsetup-rollback.dmg`（**旧端末の今の状態を `~/.macsetup-restore-backup-<日時>` へ退避してから**、新端末の記録で置き換える） |
| 7 | 旧端末 | 実行役と起動役を再開する（下記）。続けて実行役が online・起動役が読み込み済みであることを確かめる |

旧端末の再開:

```sh
for p in ~/Library/LaunchAgents/actions.runner.*.plist; do
  case "$p" in *.bak) continue ;; esac
  launchctl bootstrap "gui/$(id -u)" "$p"
done
for slot in A B; do
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.krtsato.watcher.nightly-launcher.$slot.plist
done
```

新端末の実行役の登録は残ります。止めたままにするか、後で手順 14 と同じ要領で消します。
新端末で数日動かしていた場合も、その間に進んだ処理済みの記録が旧端末へ戻るので、送信済みの動画を再送することはありません。

## 道具の置き場

| 命令 | スクリプト | 読むもの |
| --- | --- | --- |
| `make cutover-trial` | `scripts/cutover-trial.sh` | 手元の複製を `git fetch origin main`（読むだけ）して、origin/main の `.github/workflows/*.yaml` |
| `make cutover-check` | `scripts/cutover-check.sh` | 予定表・ワークフロー定義（origin/main）・GitHub の run と job（**読み取りだけ**） |
| 共有の部品 | `scripts/cutover-lib.sh` | 完了の一覧の導出 |
| 検査 | `scripts/test-cutover.sh` | 一時の git リポジトリと偽の `gh`・固定の JSON（先頭の確認だけは本物の複製を fetch する） |

- 複製の場所は既定で `~/dev/me`（`REPOS_ROOT` で変えられる）。必要な複製は実行役の 5 本と `watcher`。予定表は watcher の origin/main の `cmd/nightly-launcher/plan.json`
- 完了の一覧を**書き写さない**のは、予定表やワークフローを変えたとき黙ってずれるため。代わりに `scripts/test-cutover.sh` が
  「21 単位・試し実行 11 本・夜間で確かめる 7 本」を固定して、定義が動いたことに気づけるようにしています
  （定義を意図して変えたときは、そのテストの期待を直します）
