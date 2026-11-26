# sbx-foundry

自宅の開発環境を [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)（`sbx`）に統一するための kit 置き場。

エージェントを含まない空の sandbox（`shell` workload）を作り、Claude Code Desktop から Remote SSH で microVM に入って作業する構成を前提にしています。

> [!WARNING]
> Kit v3 は experimental で、仕様が変わる可能性があります。
> `base-kit/` は `sbx` で実機確認済みです（下の「検証」を参照）。`docker buildx` での OCI layout のビルドは通りました。`kit-tck` での検証はまだです。

## 構成

kit は層で重ねます。下の層ほど全プロジェクト共通です。

```text
sbx/git-ssh-sign   公式。SSH 鍵での Git 署名
base-kit/          共通。ssh ログイン時のシェルを bash にする
projects/<name>/   プロジェクト固有（network 許可、credential、port、初回セットアップ）
```

```text
sbx-foundry/
├── base-kit/
│   └── base-kit.yaml     # 宣言のみの mixin（provides: base-kit）
└── projects/
    ├── agent-sandbox/    # kubernetes-sigs/agent-sandbox 用（下の節）
    └── <name>/           # base-kit の上に重ねる mixin。requires: ["base-kit"]
```

- 公式 kit（<https://hub.docker.com/u/sbx>）で足りるものは自作せず、`--kit` で並べて使います。
- `projects/<name>/` は `requires: ["base-kit"]` を宣言して、base-kit が無い組み合わせを compose 時に弾きます。

## base-kit がすること

| 内容 | 仕組み |
| --- | --- |
| ssh ログイン時のシェルを bash にする | install フック（root）で `agent` のログインシェルを bash に変更 |
| 変更が効かなかった場合の保険 | `/etc/profile.d/00-base-kit-bash.sh` が、対話の sh ログインのときだけ `exec bash -l` |

| DHI のバナーを対話シェルだけにする | `/etc/profile.d/01-dhi.sh` は対話かどうかを見ず、`$HOME` ごとの初回の login shell で ANSI 付きバナーを stdout に出す。`bash -lc` の出力を読むプログラムが壊れるため、元のスクリプトを退避して対話時だけ読み込む |
| openssh-server を導入して起動 | install フックで apt、startup フックで sshd を起動（公開鍵認証のみ） |
| `authorized_keys` を作る | 起動のたびに、転送された SSH agent の公開鍵（`ssh-add -L`）から生成 |
| sshd セッションに環境変数を渡す | 起動のたびに PID 1 の環境（proxy、CA、`SSH_AUTH_SOCK`）を `~/.ssh/environment` に書き出す |
| 22 番ポートを公開 | `port@1`。ホスト側は一時ポートが割り当てられる |

`sbx run` 経由だと bash になるのに、通常の ssh だと sh で入る問題への対処です。非対話の `ssh host cmd` には触りません。

### なぜ sshd を持つのか

`sbx ssh proxy` 経由（`<name>.sbx`）では、ターミナルからは入れるものの、Claude Desktop の接続が `RPC transport closed during capability handshake` で失敗します。base-kit を載せない sandbox でも同じでした。VM 内には元々 sshd がありません。そのため、sshd を VM 内で起動し、固定ポートに出して通常の ssh としてつなぎます。仕組みは公式の `sbx/codex-app-server` kit を参考にしています。

sshd の認証には、ホストの SSH agent の鍵をそのまま使うので、接続のたびに Secretive の Touch ID を求められます。`sbx/git-ssh-sign` が agent の転送を担うため、**必ず併用してください**（無いと `authorized_keys` が空のままで入れません）。

### Claude Desktop から接続する

1. ポートを固定する（一時ポートが割り当て済みなら、`sbx ports <name>` で確認して使ってもよい）

   ```bash
   sbx ports myproj --publish 127.0.0.1:2222:22
   ```

2. `~/.ssh/config` に、`.sbx` で終わらない別名を追加する（`*.sbx` の ProxyCommand に当たらないようにする）

   ```text
   Host myproj-sshd
       HostName 127.0.0.1
       Port 2222
       User agent
       HostKeyAlias myproj-sshd
       StrictHostKeyChecking accept-new
   ```

3. Desktop の「+ Add SSH connection」で `myproj-sshd` を指定する

sandbox を作り直すと host key が変わるため、`~/.ssh/known_hosts` の `myproj-sshd` の行を消してください。

## Git 署名（公式 `sbx/git-ssh-sign`）

base-kit には含めず、公式 kit を一緒に載せます。

- 署名設定と、ホストの SSH agent が持つ鍵からの署名鍵選択を担います。
- 鍵が複数あるとき、リポジトリの remote が github.com で sandbox 内の `gh` が認証済みなら、GitHub に Signing Key として登録済みの鍵を選びます。それ以外は agent の先頭の鍵にフォールバックします。
- フォールバックしたときは署名は付くものの、GitHub で **Unverified** になります。確認は sandbox 内で `/bin/sh ~/.config/git/ssh-signing-key-command` を実行します。
- remote を持たないローカルだけのリポジトリでは照合が働かず、先頭の鍵になります。GitHub 上のリポジトリ（remote が github.com）では、登録済みの Signing Key が選ばれることを確認済みです。
- `sbx create` に `--kit sbx/git-ssh-sign:latest` を付け忘れると agent が転送されず、`ssh-add -L` が失敗します（`SSH_AUTH_SOCK` が空で、中継も起動しません）。
- author の `user.name` / `user.email` はホストの git 設定から引き継ぎます。

## projects/agent-sandbox

[kubernetes-sigs/agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) の TypeScript SDK を開発するための kit です。`make test-unit` と `make test-e2e`（kind 上）を回せる環境を作ります。**未検証**です。

```bash
sbx create shell \
  --kit sbx/git-ssh-sign:latest \
  --kit sbx/mise:latest \
  --kit /path/to/sbx-foundry/base-kit \
  --kit /path/to/sbx-foundry/projects/agent-sandbox \
  --name agent-sandbox /path/to/agent-sandbox
```

| 内容 | 仕組み |
| --- | --- |
| Go 1.27.3 / Node 22.22.0 / Python 3.14 / kubectl | install フックで `mise use -g`（kubectl は latest） |
| kind と、そのラッパー（`/usr/local/bin/kind`） | kind は `mise install` のみ（PATH に載せない）。ラッパーが `kind create cluster` の成功後に、sandbox の egress proxy の CA（`PROXY_CA_CERT_B64`）を各 node に入れて containerd を再起動する。それ以外のサブコマンドは本物の kind にそのまま渡す（未検証） |
| gcc / libc6-dev | install フックで apt。`make test-unit` が Go を `-race` 付きで回し、cgo（C コンパイラ）を要求するため |
| PyYAML | install フックで pip（`deploy-to-kube` などが system の python3 で import するため） |
| `/dev/kmsg` | startup フック（root）で `mknod`。kind の node が起動するために必要（仮説、要検証） |
| inotify 上限 | startup フックで sysctl（失敗しても無視） |
| network | install と runtime に同じホスト一覧（GitHub、Go、npm、PyPI、Docker Hub、gcr.io、registry.k8s.io など） |

- Docker は sbx が VM 内で起動している dockerd を使います（`docker buildx` が入っているかは要確認）。
- `sbx/mise` は公式 kit です。名前は Docker Hub の `sbx/mise-kit` かもしれないので、`sbx create` で解決できなければ読み替えてください。
- ホストが足りずに失敗したときは、拒否されたホストを `agent-sandbox.yaml` の network 許可に足します。
- e2e は kind と image build でメモリを使います。足りなければ `sbx create` のリソース指定を増やしてください。
- **ディスク:** Docker のストア（`/var/lib/docker`）はルートとは別のボリュームで、既定は 10g です。e2e のイメージビルドで `no space left on device` になるため、sandbox を作る前にホストで増やします（新しく作る sandbox にだけ効きます）。

  ```bash
  sbx settings set sandbox.disk.dockerVolume 40g
  ```

**テスト実行時の注意（egress proxy）:** sandbox の外向き通信は proxy（`gateway.docker.internal:3128`）を通ります。ローカル宛の通信まで proxy に回って `403 Forbidden` になるテストがあるため、`NO_PROXY` を足して実行します。`NO_PROXY` は PID 1 の環境で決まり、kit の hook からは変えられないので、kit ではなく実行時に指定します。

```bash
NO_PROXY=172.16.0.0/12,192.0.2.0,$NO_PROXY make test-unit
NO_PROXY=172.16.0.0/12,192.0.2.0,$NO_PROXY make test-e2e
```

- `172.16.0.0/12` は kind の docker network 宛（Python e2e の gateway mode）、`192.0.2.0` は unit テストが使う接続拒否用のアドレスです。
- `test_kubeconfig_targets_the_injected_cluster` は、proxy 変数が kubeconfig の `proxy-url` に混入して落ちます。`NO_PROXY` では直らないため、このテストだけ proxy 変数を外します。

  ```bash
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    python -m pytest -k test_kubeconfig_targets_the_injected_cluster
  ```

- **kind node の image pull（x509）:** sandbox の proxy は TLS を中継し、proxy 独自の CA で署名した証明書を返します。VM はその CA を信頼しますが、kind node の containerd は信頼しないため、`crictl pull` が `x509: certificate signed by unknown authority` で失敗し、Pod が `ErrImagePull` になります（Go e2e の `TestSandboxFailedPodPolicyRecreate` など 4 件がこれで落ちていました）。`make test-e2e` は毎回 `kind create cluster` で作り直すため、手動で CA を入れても消えます。kit の `kind` ラッパーが作成のたびに CA を入れます。`which -a kind` の先頭が `/usr/local/bin/kind` であることを確認してください。
- **proxy の迂回（NO_PROXY）:** Python e2e（gateway mode）は、kind の docker network 上の gateway（`172.19.0.x:80`）に VM から HTTP でつなぎます。sandbox の `HTTP(S)_PROXY` は**ホスト側から**接続しにいくため、VM の中にしか無いこのネットワークは、proxy を通すと `403`（許可なし）か `502`（許可しても接続できない）になります。許可を足しても直らず、`NO_PROXY` / `no_proxy` に足して迂回するのが正解です。`requests` は小文字の `no_proxy` を優先するので、**両方**に入れます。kit は `/etc/base-kit/no-proxy.d/agent-sandbox.list` に宛先（`172.16.0.0/12`、unit テスト用の `192.0.2.0`）を置き、base-kit が起動のたびに ssh セッションの `NO_PROXY` / `no_proxy` に足します（`~/.ssh/environment` 経由のため、**ssh で入ったシェルにだけ**効きます。`sbx exec` では手で指定します）。実機で、ここまでの手順で gateway モードが通ることを確認済みです。
- **ポリシーに書かないこと:** proxy 経由の許可は、ホスト側のネットワークへの許可になります。kind の CIDR（`172.16.0.0/12`）や `host.lima.internal`（ホスト自体を指すとみられる名前）は、許可しないでください。拒否された宛先は `sbx policy log <name> --json` の `blocked` で確認できます。`sbx policy allow network --sandbox <name> ...` で CLI から足したルールは、sandbox を作り直すと消えます。

確認する順番:

1. `ssh` で入り `go version` / `node -v` / `python3 -c 'import yaml'` / `kind version` / `kubectl version --client` が通る
2. `make test-unit`
3. `ls -l /dev/kmsg` があり、`kind create cluster` が成功する
4. `make test-e2e`
5. 署名付きでコミットできる

## 前提

- ホストは macOS
- `sbx` 0.51.0 以上（SSH 接続機能が必要）
- 署名鍵は [Secretive](https://github.com/maxgoedjen/secretive)（Secure Enclave）に置く
- 署名用の公開鍵を GitHub に **Signing Key** として登録済み

## ホスト側の初回設定

SSH agent を Secretive のソケットに向けます。

```bash
sbx settings set ssh.agentForwardingEnabled true
```

```bash
sbx settings set ssh.agentSocketPath ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh
```

```bash
sbx daemon restart
```

設定が既存 sandbox に反映されるのは daemon 再起動後です。署名のたびにホスト側で Touch ID を求められます。

`~/.ssh/config` に `*.sbx` の管理ブロックを入れます（1 回だけ）。

```bash
sbx setup ssh
```

## 使い方

```bash
sbx create shell \
  --kit sbx/git-ssh-sign:latest \
  --kit /path/to/sbx-foundry/base-kit \
  --kit /path/to/sbx-foundry/projects/myproj \
  --name myproj .
```

```bash
ssh myproj.sbx
```

停止中の sandbox は SSH 接続で自動起動します。Claude Desktop では「+ Add SSH connection」で SSH Host に `myproj.sbx` を入れ、Port と Identity File は空のままにします。

### ghcr から使う（base-kit）

base-kit は OCI イメージとして `ghcr.io/khirotaka/sbx-foundry-base-kit` に公開します（タグは `<version>` と `latest`）。ローカルのパスの代わりに参照で指定できます。

```bash
sbx create shell \
  --kit sbx/git-ssh-sign:latest \
  --kit ghcr.io/khirotaka/sbx-foundry-base-kit:0.2.2 \
  --name myproj .
```

> [!NOTE]
> 公開後の `--kit` での解決は、初回公開時に確認します。

公開はタグ駆動です（[workflow](.github/workflows/publish-base-kit.yml)）。`base-kit/base-kit.yaml` の `version` を上げたうえで、同じ値のタグを push します。

```bash
git tag base-kit-v0.2.2 && git push origin base-kit-v0.2.2
```

## 検証

`sbx kit validate` は v3 のソース kit を受け付けないため、`inspect` を使います。

```bash
sbx kit inspect ./base-kit
```

実機での確認項目:

1. `sbx create shell --kit ./base-kit ...` が compose できる（確認済み）
2. `ssh <name>.sbx` で入って `echo $0` が bash になる（確認済み）
3. `git-ssh-sign` と組み合わせて、GitHub 上のリポジトリで commit すると署名が付く（確認済み）
4. install フックで openssh-server が入り、sshd が起動する（確認済み）
5. sshd 経由で入れて、Secretive の鍵で署名できる（確認済み）
6. Claude Desktop から sshd 経由で接続できる（確認済み）

## 今後の候補

- mise の導入は公式 `sbx/mise-kit` で足りるか確認する
- `projects/` の雛形（`requires: ["base-kit"]` 入り）
- `sbx create` をまとめたシェル関数

## License

[MIT](LICENSE)
