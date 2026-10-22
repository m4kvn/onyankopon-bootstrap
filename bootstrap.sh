#!/bin/bash
#
# onyankopon-bootstrap
#
# 新しい Mac で、private リポジトリ onyankopon を clone して init.sh を実行できる状態まで持っていく。
# onyankopon 本体は 1Password の鍵が無いと clone できないので、このスクリプトだけは public に置く。
#
#   対話（通常の新しい Mac）:
#     curl -fsSL https://raw.githubusercontent.com/m4kvn/onyankopon-bootstrap/main/bootstrap.sh | bash
#
#   無人（tart の VM 検証など。1Password.app は入れず、Service Account で op を使う）:
#     OP_SERVICE_ACCOUNT_TOKEN=... bash bootstrap.sh
#
#   clone までで止める（init.sh を実行しない）:
#     ONYANKOPON_BOOTSTRAP_ONLY=1 bash bootstrap.sh
#
#   引数はそのまま init.sh に渡す（例: bash bootstrap.sh dotfiles agents repos）。
#
# やること（上から順。済んでいる step は飛ばすので何度実行してもよい）:
#   1. Xcode Command Line Tools
#   2. Homebrew
#   3. 1Password CLI (op)。Service Account でなければ 1Password.app も入れる
#   4. 1Password へのサインインを待つ（人が 1Password.app にサインインし「1Password CLI と連携」を ON にする。
#      確認は op vault get。アプリ連携では op whoami が通らないことがある）
#   5. 1Password の SSH Key アイテムから GitHub 用の鍵を ~/.ssh に書き出し、~/.ssh/config と known_hosts を整える
#   6. onyankopon を ~/.onyankopon に clone して init.sh を実行する
#
# 方針:
#   - シークレットの実値はこのファイルに書かない。1Password の Secret Reference (op://) だけを書く。
#   - 参照は Vault ID / Item ID 形式（アイテム名の変更や同名アイテムの曖昧さを避ける）。
#   - 標準入力は使わない（curl | bash で stdin がスクリプト自身になるため）。待ちはすべてポーリング。
set -u

TAG="[onyankopon-bootstrap]"

# ---------------------------------------------------------------------------
# 設定（環境変数で上書きできる）
# ---------------------------------------------------------------------------
# GitHub 用 SSH 鍵。1Password の「SSH Key」カテゴリのアイテムを指す。
#   Vault: Personal (4dhtkh2u5pwkkhncatoppqjupm)
#   Item: m4kvn_github (dvfwispadkar7hpkg7lbnqj5om)。`op item list --categories "SSH Key"` で確認できる。
#   フィールドはラベル（UI 言語で「private key」「秘密鍵」と変わる）ではなく ID `private_key` で指す。
#   `?ssh-format=openssh` を付けると保存形式に関わらず OpenSSH 形式で取り出せる。
OP_VAULT_ID="${OP_VAULT_ID:-4dhtkh2u5pwkkhncatoppqjupm}"   # Personal。サインイン確認にも使う
GITHUB_SSH_KEY_REF="${GITHUB_SSH_KEY_REF:-op://$OP_VAULT_ID/dvfwispadkar7hpkg7lbnqj5om/private_key?ssh-format=openssh}"
GITHUB_SSH_KEY_PATH="${GITHUB_SSH_KEY_PATH:-$HOME/.ssh/m4kvn_github}"   # onyankopon の ~/.ssh/config が指す場所に合わせる
ONYANKOPON_REPO="git@github.com:m4kvn/onyankopon.git"
ONYANKOPON_ROOT="$HOME/.onyankopon"
SIGNIN_TIMEOUT_SEC="${SIGNIN_TIMEOUT_SEC:-1800}"   # サインイン待ちの上限（既定 30 分）

log()  { echo "$TAG $*"; }
warn() { echo "$TAG warning: $*" >&2; }
die()  { echo "$TAG error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS 専用です"

# ---------------------------------------------------------------------------
# 1. Xcode Command Line Tools（git と Homebrew に必要）
# ---------------------------------------------------------------------------
step_xcode_clt() {
    if xcode-select -p >/dev/null 2>&1; then
        log "Xcode Command Line Tools: 導入済み"
        return 0
    fi
    # まず無人で試す: この印を置くと softwareupdate のカタログに CLT が現れる（Apple の installondemand の仕組み）。
    # ssh 越しや VM など GUI を操作できない環境でも止まらずに済む。
    local marker=/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress label=""
    touch "$marker"
    # ラベルは macOS 26 で "Command Line Tools for Xcode 26.6-26.6"、古い macOS で "Command Line Tools for Xcode-14.3" の形。
    # 実行中の macOS と同じメジャー版の最新を選び、無ければ最新を選ぶ。
    label="$(softwareupdate -l 2>/dev/null | grep -o 'Command Line Tools for Xcode[ -][0-9][0-9.]*\(-[0-9.]*\)\{0,1\}' | sort -V \
        | awk -v major="$(sw_vers -productVersion | cut -d. -f1)" '{ all=$0; if ($0 ~ "Xcode[ -]" major "[.]") same=$0 } END { print (same != "" ? same : all) }')"
    if [ -n "$label" ]; then
        log "Xcode Command Line Tools を softwareupdate で導入します: ${label}（sudo のパスワードを求められることがあります）"
        sudo softwareupdate -i "$label" >/dev/null 2>&1 || warn "softwareupdate での導入に失敗しました。ダイアログで導入します"
    fi
    rm -f "$marker"
    if xcode-select -p >/dev/null 2>&1; then
        log "Xcode Command Line Tools: 導入完了"
        return 0
    fi
    # 無人で入らなければダイアログで導入する
    log "Xcode Command Line Tools を導入します（ダイアログが出たら「インストール」を押してください）"
    xcode-select --install >/dev/null 2>&1 || true
    local waited=0
    until xcode-select -p >/dev/null 2>&1; do
        sleep 10
        waited=$((waited + 10))
        [ "$waited" -ge "$SIGNIN_TIMEOUT_SEC" ] && die "Xcode Command Line Tools の導入を待ちきれませんでした"
    done
    log "Xcode Command Line Tools: 導入完了"
}

# ---------------------------------------------------------------------------
# 2. Homebrew
# ---------------------------------------------------------------------------
step_brew() {
    if [ -x /opt/homebrew/bin/brew ]; then
        log "Homebrew: 導入済み"
    else
        log "Homebrew を導入します（sudo のパスワードを求められることがあります）"
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
            || die "Homebrew の導入に失敗しました"
    fi
    eval "$(/opt/homebrew/bin/brew shellenv)"
}

# ---------------------------------------------------------------------------
# 3. 1Password CLI と 1Password.app
# ---------------------------------------------------------------------------
step_1password() {
    if ! command -v op >/dev/null 2>&1; then
        log "1Password CLI を導入します"
        brew install --cask 1password-cli || die "1password-cli の導入に失敗しました"
    fi
    if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        log "Service Account を使うため 1Password.app は導入しません"
        return 0
    fi
    if [ ! -d /Applications/1Password.app ]; then
        log "1Password.app を導入します"
        brew install --cask 1password || die "1password の導入に失敗しました"
    fi
}

# ---------------------------------------------------------------------------
# 4. サインイン待ち
#   - Service Account: OP_SERVICE_ACCOUNT_TOKEN があれば即座に確認する
#   - それ以外: 1Password.app を開き、Vault を読めるようになるまでポーリングする
#   確認は `op vault get` で行う。デスクトップアプリ連携では `op whoami` が
#   "account is not signed in" を返すのに vault/item は読める状態があり、whoami では待ちが終わらない。
# ---------------------------------------------------------------------------
op_ready() { op vault get "$OP_VAULT_ID" >/dev/null 2>&1; }

step_signin() {
    if op_ready; then
        log "1Password: サインイン済み"
        return 0
    fi
    if [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
        die "OP_SERVICE_ACCOUNT_TOKEN で Vault $OP_VAULT_ID を読めません。トークンと Vault の権限を確認してください"
    fi
    open -a 1Password || true
    cat <<MSG
$TAG 1Password.app で次を行ってください（終わるまでここで待ちます）:
$TAG   1. アカウントにサインインする（Emergency Kit の QR か、メール・Secret Key・パスワード）
$TAG   2. 設定 → 開発者 → 「1Password CLI と連携」を ON にする
MSG
    local waited=0
    until op_ready; do
        sleep 10
        waited=$((waited + 10))
        [ "$waited" -ge "$SIGNIN_TIMEOUT_SEC" ] && die "サインインを待ちきれませんでした。サインイン後にもう一度実行してください"
    done
    log "1Password: サインインを確認しました"
}

# ---------------------------------------------------------------------------
# 5. GitHub 用 SSH 鍵と ssh 設定
# ---------------------------------------------------------------------------
step_ssh_key() {
    local pub="$GITHUB_SSH_KEY_PATH.pub" tmp=""
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

    if [ -f "$GITHUB_SSH_KEY_PATH" ]; then
        log "SSH 鍵: $GITHUB_SSH_KEY_PATH は既にあります（維持）"
    else
        case "$GITHUB_SSH_KEY_REF" in
            *__ITEM_ID__*) die "GITHUB_SSH_KEY_REF の Item ID が未設定です。\`op item list --categories \"SSH Key\"\` で確認し、環境変数 GITHUB_SSH_KEY_REF かこのファイルの既定値に設定してください" ;;
        esac
        log "SSH 鍵を 1Password から書き出します: $GITHUB_SSH_KEY_PATH"
        tmp="$(mktemp "$HOME/.ssh/.bootstrap.XXXXXX")" || die "一時ファイルを作れません"
        chmod 600 "$tmp"
        if ! op read --no-newline "$GITHUB_SSH_KEY_REF" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
            rm -f "$tmp"
            die "op read に失敗しました: ${GITHUB_SSH_KEY_REF}（Vault の権限とアイテムの Item ID を確認してください）"
        fi
        printf '\n' >> "$tmp"
        if ! ssh-keygen -y -f "$tmp" > "$pub.tmp" 2>/dev/null; then
            rm -f "$tmp" "$pub.tmp"
            die "取り出した内容が SSH 秘密鍵として読めません。アイテムの種類（SSH Key）とフィールド名を確認してください"
        fi
        mv "$tmp" "$GITHUB_SSH_KEY_PATH" && mv "$pub.tmp" "$pub" && chmod 644 "$pub"
        log "SSH 鍵: 配置しました"
    fi

    # ~/.ssh/config: github.com の Host が無いときだけ追記する（既存の設定は触らない）
    if ! grep -qE '^\s*Host\s+github\.com(\s|$)' "$HOME/.ssh/config" 2>/dev/null; then
        cat >> "$HOME/.ssh/config" <<CONF

Host github.com
  User git
  IdentityFile $GITHUB_SSH_KEY_PATH
  IdentitiesOnly yes
CONF
        chmod 600 "$HOME/.ssh/config"
        log "~/.ssh/config に github.com を追記しました"
    fi

    # known_hosts: 初回 clone の対話を避ける
    if ! ssh-keygen -F github.com -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
        ssh-keyscan -t ed25519,ecdsa,rsa github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null \
            && log "known_hosts に github.com を追加しました" \
            || warn "ssh-keyscan github.com に失敗しました（ネットワークを確認）"
    fi

    # 疎通確認: 成功時 ssh は exit 1 だが "successfully authenticated" を返す
    if ssh -T -o BatchMode=yes git@github.com 2>&1 | grep -q "successfully authenticated"; then
        log "GitHub: ssh 認証 OK"
    else
        die "GitHub に ssh 認証できません。鍵が GitHub アカウントに登録されているか確認してください"
    fi
}

# ---------------------------------------------------------------------------
# 6. onyankopon を clone して init.sh に引き渡す
# ---------------------------------------------------------------------------
step_onyankopon() {
    if [ -d "$ONYANKOPON_ROOT/.git" ]; then
        log "onyankopon: $ONYANKOPON_ROOT に clone 済み"
    else
        log "onyankopon を clone します: $ONYANKOPON_ROOT"
        git clone "$ONYANKOPON_REPO" "$ONYANKOPON_ROOT" || die "onyankopon の clone に失敗しました"
    fi
    if [ -n "${ONYANKOPON_BOOTSTRAP_ONLY:-}" ]; then
        log "ONYANKOPON_BOOTSTRAP_ONLY が設定されているため init.sh は実行しません: $ONYANKOPON_ROOT/init.sh"
        return 0
    fi
    log "init.sh を実行します: $ONYANKOPON_ROOT/init.sh $*"
    exec "$ONYANKOPON_ROOT/init.sh" "$@"
}

main() {
    step_xcode_clt
    step_brew
    step_1password
    step_signin
    step_ssh_key
    step_onyankopon "$@"
}

main "$@"
