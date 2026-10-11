# 秘密と記録を運ぶ `make secrets-*` の詳しい説明

旧い Mac から新しい Mac へ、**許可した一覧だけ**を暗号化ディスクイメージ（AES-256・APFS）で運ぶ仕組みです。
新しい道具は要りません。**合言葉は `hdiutil` が端末で直接尋ねます**（引数にも環境変数にも渡しません）。

切り替えの手順の中での使いどころは [cutover.md](cutover.md) の手順 9 にあります。ここは、命令ごとの動きと決まりを詳しく書いたものです。

## 先に知っておくこと

| 決まり | 内容 |
| --- | --- |
| 対話の端末から流す | Ansible・CI・バックグラウンドからは動きません（`hdiutil` が制御端末で合言葉を尋ねるため） |
| 公開リポジトリなので | イメージはリポジトリの外へ作り（権限 0600）、秘密・ハッシュ・NotebookLM のプロファイル名は出力へ出しません（`<プロファイル1>` などの別名で表示）。`cp`・`mv`・`hdiutil` などの道具のエラーも、別名（長い名前から置き換え）を通して表示します |
| 一覧の正本 | 点検と同じ `ansible/roles/doctor/vars/main.yaml` の `doctor_config_files`（複製しません） |
| 2 回に分けて動く | まず Ansible が許可一覧を 0600 の一時ファイルへ書くだけ（`ansible/secrets.yaml`）、次に `secrets.sh` を端末へ繋いだまま直接実行します。一時ファイルは成功でも失敗でも消します |

## 命令

```sh
make secrets-list                                           # 運ぶ物を確かめる（何も作らない）
make secrets-export OUT=$HOME/Desktop/macsetup-secrets.dmg  # 旧い Mac。OUT は絶対パスの .dmg で、まだ無いこと
make secrets-import IMAGE=/Volumes/USB/macsetup-secrets.dmg # 新しい Mac。最後に make doctor PHASE=cutover を流す
make secrets-restore IMAGE=/Volumes/USB/macsetup-secrets.dmg # 旧い Mac へ戻すとき
make secrets-recover                                        # import・restore が強制終了などで途中で止まったとき
scripts/test-secrets.sh                                     # 偽のホームでの検査
```

| 命令 | 動き |
| --- | --- |
| `list` | 運ぶ物と、runner・夜間の起動の停止状態を表示する（何も作らない） |
| `export` | **runner 5 体と夜間の起動 2 枠が止まっていること**を確かめてから、一覧を集める。必須の物が欠けていたり、出力先がリポジトリの中・既に存在するときは何も作らず止まる。件数の目録 `MANIFEST.json` をイメージの中に入れる |
| `import` | イメージを読み取り専用で取り付け、目録と中身の一致・許可一覧の外の物が無いこと・**必須の項目（必須の子ファイルを含む）が全部あること**（任意の物は無くてよい）を検査する。**衝突（置き先に既に在る物）を先にまとめて調べ、1 件でもあれば何も変えずに止まる**。ホーム直下の一時の置き場へ写して件数と権限を検査し、**変更の前に意図を記録（書き込み先行）してから**1 項目ずつ置く。途中で失敗したら記録と実際の状態から配置前へ戻す。イメージは成功でも失敗でも必ず取り外し、**取り外せなければ取り付け先を表示して止まり、取り付けたまま配置しない**。最後に `make doctor PHASE=cutover` を流し、その終了コードを返す |
| `restore` | `import` と同じ検査の後、置き先に在る物を `~/.macsetup-restore-backup-<日時>`（0700）へ退避してから置く。失敗したら退避した物を戻す。runner と夜間の起動が停止していることも要る |
| `recover` | 強制終了で止まった `import`・`restore` の跡を配置前へ戻す（下の「途中で止まったとき」） |

### 止まっていることの確かめ方

`export` と `restore` は、次のどれかに当てはまると拒否します。確かめられないときは、止まっているとみなしません。

- launchd に読み込まれている
- `.runner` が有るのに `.service` が無く、確かめられない
- `bin*/Runner.Listener` の process が動いている

## 運ぶ物

| 分類 | 運ぶ物 | 権限 |
| --- | --- | --- |
| `auth`（認証） | NotebookLM の cookie と `nlm` の認証・プロファイル、mediable・YouTube・TradingView の認証、`~/.codex/auth.json` | ファイル 0600・ディレクトリ 0700 |
| `state`（処理済みの記録） | YouTube 送信済み・字幕同期・NotebookLM 同期・詰まった字幕・（あれば）飛ばした動画。無いと送信済みの動画を全件再送する | 0600 |
| `inbox`（受け箱と保留） | 各 `notebooklm-inbox/`・`withheld-drafts/` をディレクトリごと | 0700 配下、ファイル 0600 |

`required: false` の項目は、あれば運びます。ディレクトリの中の `.DS_Store`・`.lock`・`*.lock` は運びません。

### 運ばない物

| 物 | 理由・その後 |
| --- | --- |
| Claude と gh のログイン | キーチェーンにあり、ファイルとして運べません。新しい Mac で手でログインし直します（[cutover.md](cutover.md) の手順 2 と 10） |
| watcher の `.launcher/state-*.json`（夜間の起動の再開記録） | 運びません。**切り替えは全枠が完了してからだけ**にします |
| 移行前の写し・`.local/`・`mcp-mediable/captions/` など、許可一覧に無い物 | 運びません |

## 途中で止まったとき

処理の強制終了（`kill -9` など）で止まると、ホーム直下に `.macsetup-import.*`（一時の置き場と記録）が残ります。
停電や OS の異常終了までは保証しません（記録をディスクへ確定させる手段がシェルに無いため）。
その場合は `make doctor PHASE=cutover` で不足を確かめ、イメージから持ち込み直します。

跡が残っている間は、`import`・`restore` が「前回の途中で止まった跡がある」と言って拒否します。
このときは `make secrets-recover` を実行してください。記録（書き込み先行）と、実際に在る物を突き合わせて、
置いた物を消し、退避した物を元へ戻します（やり直しても同じ結果。実行中の process が使っている置き場には触りません）。
戻せない行（元の場所と退避先の両方に物が在るなど）があれば、件数と記録の場所を表示して失敗します。手で直してください。

## テスト専用の環境変数

`make` へ渡します。実運用では使いません。

| 変数 | 用途 |
| --- | --- |
| `SECRETS_HOME` | ホームの差し替え |
| `SECRETS_PROFILES_OVERRIDE` | プロファイル名（JSON の配列） |
| `SECRETS_PATH_PREFIX` | 偽の `launchctl` を PATH の先頭へ置く |
| `SECRETS_TEST_STDINPASS=1` | 合言葉を標準入力から `-stdinpass` で渡す |
| `SECRETS_TEST_FAIL_AFTER` | 途中で失敗させる |
| `SECRETS_TEST_SKIP_DOCTOR` | 最後の点検を飛ばす |
| `SECRETS_TEST_KILL_AFTER_MOVE` | N 回目の `mv` の直後に SIGKILL |

`scripts/test-secrets.sh` は同じ `make secrets-*` を流し、擬似端末（`script`）で対話の合言葉入力も確かめます。
往復・衝突・途中の失敗・許可外・拒否・restore・取り外し・出力に名前や中身が出ないことも確かめます。
