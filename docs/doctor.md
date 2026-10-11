# 点検 `make doctor` の詳しい説明

この Mac の状態を**読むだけ**で点検する命令です（何も変更しません）。
最初の失敗で止まらず、失敗と警告を溜めて、最後に項目名（パス・リポジトリと名前・runner）つきで一覧にします。
失敗が 1 件でもあれば終了コードは 0 以外になります。

基本の使い方は [README.md](../README.md) の「新しい Mac を用意する」にあります。ここは、何を見るかと判定の決まりを詳しく書いたものです。

## 使い方

点検には 3 つの場面があり、`PHASE` で選びます（既定は `ready`）。

| 場面 `PHASE` | いつ使うか | 命令 |
| --- | --- | --- |
| `ready`（稼働） | 普段。夜間の自動実行が動いている状態 | `make doctor` |
| `pre-import`（持ち込み前） | 旧い Mac から秘密と記録を持ち込む前 | `make doctor PHASE=pre-import` |
| `cutover`（切り替え中） | 持ち込みの後、runner を起動する前 | `make doctor PHASE=cutover` |

壊して確かめる検査は `scripts/test-doctor.sh` です（欠けた必須ファイル・存在しない複製・`SessionCreate=true` の plist を、名指しで検出するかを確かめます。遅いテストです）。

## 見るもの

| 見るもの | 内容 |
| --- | --- |
| 秘密と記録 | `~/.config` 配下の認証・処理済みの記録・受け箱と `~/.codex/auth.json`。存在・種別・権限だけ（中身は読まない） |
| 手元の複製 | 各リポジトリの `*_CLONE_DIR`（8 組）を GitHub から読み、git の複製で origin が一致するか。ワークフローが呼ぶ入口ファイルも |
| 道具 | `nlm`（固定版）・`docker info`・Docker の host networking・`claude`・`codex`・`gh` |
| ログイン | `gh`・管理者権限・`codex`・`claude`・NotebookLM（終了コードだけを見る）。`gh`・`claude`・`codex` は runner と同じ環境（`env -i` と runner の `.path`）でも 1 回確かめる |
| GitHub 側 | 移行に必須の秘密と変数（名前の有無だけ。全設定の棚卸しではない。秘密 6 組は「移行に必須の組」） |
| runner と夜間の起動 | `.path` の先頭が mise の shims・`SessionCreate=false`・停止/online・LaunchAgent の読み込み |
| OpenD（moomoo の API ゲートウェイ） | `127.0.0.1:11111`。`ready` では土曜 01:30〜月曜 01:30 以外は失敗、その間と他の場面は警告（日本時間。`DOCTOR_NOW` / `doctor_now` で「いま」を上書きできる） |

## 場面ごとの期待

| 項目 | `pre-import` | `cutover` | `ready` |
| --- | --- | --- | --- |
| 持ち込む秘密と記録・codex/NotebookLM のログイン | 無いことを期待（あれば衝突の警告） | 有る | 有る |
| runner | 登録済み・停止中 | 登録済み・停止中 | GitHub 上で online・ラベル一致 |
| 夜間の起動 | plist あり・停止中 | plist あり・停止中 | 読み込み済み |
| それ以外 | 必須 | 必須 | 必須 |

## ログインの確認の限界

runner と同じ環境での確認は、PATH と環境変数の差を拾います。
キーチェーンのセッションの差は、plist の `SessionCreate=false` の点検が受け持ちます。
残る差（launchd から起こした process での確認）は、切り替えの試し実行と夜間の本番でしか確かめられません
（点検は launchd の仕事を作りません）。

NotebookLM のプロファイル名は出力へ出さず、`プロファイル1`・`プロファイル2` の別名で表示します。

## 一覧の正本と、テスト用の差し込み

点検の一覧（パス・分類・権限・用途・runner・入口ファイル）の正本は `ansible/roles/doctor/vars/main.yaml` です。
複製の場所と NotebookLM のプロファイル名は書かず、GitHub の変数を実行時に読みます。

テスト用に、次の変数を差し替えられます。

| 変数 | 用途 |
| --- | --- |
| `doctor_home` | ホームの場所 |
| `doctor_launchagents_dir` | LaunchAgent の置き場 |
| `doctor_extra_config_files` | 点検する秘密と記録の追加 |
| `doctor_clone_dir_overrides` | 複製の場所 |

## 保守する人向けの決まり

- 点検の本体は `ansible/roles/doctor/files/checks.sh` です。グループごとに `FAIL|`・`WARN|` の行を出し、Ansible が溜めて最後に一覧と失敗にします
- 入口ファイルの一覧は、ワークフローの `$X_CLONE_DIR/...`・`git archive origin/main`・`git show` の使い方から導出しています。呼び出し先が動いたら一覧も直します
- プロファイル名は `checks.sh` の shell 変数の中だけで持ち、出力・Ansible の変数へ出しません（`scripts/test-doctor.sh` が全出力を探して 0 件を確かめます）
