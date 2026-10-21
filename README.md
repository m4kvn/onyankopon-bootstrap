# onyankopon-bootstrap

新しい Mac で [onyankopon](https://github.com/m4kvn/onyankopon)（private）を clone して `init.sh` を実行できる状態まで持っていくスクリプト。
onyankopon は 1Password にある GitHub 用の鍵が無いと clone できないので、その手前の「1Password を入れてサインインし、鍵を取り出す」部分だけをこの public リポジトリが担う。

## 使い方

```sh
curl -fsSL https://raw.githubusercontent.com/m4kvn/onyankopon-bootstrap/main/bootstrap.sh | bash
```

途中で 1Password.app が開くので、サインインして「設定 → 開発者 → 1Password CLI と連携」を ON にする。スクリプトはそれを待ってから続きを行い、最後に onyankopon の `init.sh` を実行する。

| 変数 / 引数 | 意味 |
| --- | --- |
| 引数 | そのまま `init.sh` に渡す（例: `bash bootstrap.sh dotfiles agents repos`） |
| `ONYANKOPON_BOOTSTRAP_ONLY=1` | clone までで止めて `init.sh` を実行しない |
| `OP_SERVICE_ACCOUNT_TOKEN` | 1Password の Service Account で op を使う。1Password.app を入れず、サインイン待ちもしない（tart の VM 検証向け） |
| `GITHUB_SSH_KEY_REF` | 鍵を取り出す `op://` 参照。既定値は `bootstrap.sh` 冒頭にある |
| `OP_VAULT_ID` | サインイン確認（`op vault get`）に使う Vault。既定は Personal |
| `GITHUB_SSH_KEY_PATH` | 鍵の書き出し先。既定は `~/.ssh/m4kvn_github`（onyankopon の `~/.ssh/config` が指す場所） |
| `SIGNIN_TIMEOUT_SEC` | サインインと Xcode CLT を待つ上限秒。既定 1800 |

何度実行しても同じ結果になる。済んでいる step は飛ばし、既にある鍵や `~/.ssh/config` の `Host github.com` は触らない。

## 流れ

1. Xcode Command Line Tools（ダイアログが出たらインストールを押す）
2. Homebrew
3. 1Password CLI（`op`）。Service Account でなければ 1Password.app も
4. 1Password へのサインインを待つ
5. 1Password の SSH Key アイテムから GitHub 用の鍵を `~/.ssh` に 600 で書き出し、`~/.ssh/config` の `Host github.com` と `known_hosts` を整え、`ssh -T git@github.com` で疎通を確認する
6. onyankopon を `~/.onyankopon` に clone して `init.sh` を実行する

## 前提

- Apple Silicon の macOS。
- 1Password の Personal vault に GitHub 用の鍵が「SSH Key」カテゴリのアイテムとして保存され、その公開鍵が GitHub アカウントに登録されていること。
- `bootstrap.sh` の `GITHUB_SSH_KEY_REF` が鍵アイテムを指していること（既定は Personal の `m4kvn_github`）。Item ID は次で確認する。フィールドはラベルではなく ID `private_key` で参照する（ラベルは UI 言語で変わる）。

```sh
op item list --categories "SSH Key"
```

## 方針

- シークレットの実値はこのリポジトリに書かない。`op://Vault ID/Item ID/field` の Secret Reference だけを書く。参照先は Vault と Item の ID 形式にし、アイテム名の変更に影響されないようにする。
- 標準入力は使わない。`curl | bash` では stdin がスクリプト自身になるので、人の操作待ちはすべてポーリングで行う。
- 鍵はディスクに書き出す（onyankopon の `~/.ssh/config` が `IdentityFile` 方式のため）。1Password SSH agent 方式に移すときは、ここでの書き出しをやめて `IdentityAgent` を設定する形に変える。

## tart で検証する

使い捨ての macOS VM で bootstrap と onyankopon の `init.sh` を通しで試す。個人アカウントを VM に入れないよう、検証用 Vault だけを読める Service Account を使う。

```sh
brew install openai/tools/tart
tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest onyankopon-test
tart run onyankopon-test --no-graphics &
ssh admin@"$(tart ip onyankopon-test)"   # パスワードは admin
```

VM 内:

```sh
export OP_SERVICE_ACCOUNT_TOKEN=...   # 検証用 Vault の読み取り専用 Service Account
export GITHUB_SSH_KEY_REF="op://<検証用 Vault ID>/<Item ID>/private_key?ssh-format=openssh"
curl -fsSL https://raw.githubusercontent.com/m4kvn/onyankopon-bootstrap/main/bootstrap.sh | bash -s -- dotfiles agents repos
```

検証が終わったら `tart delete onyankopon-test` で破棄する。
