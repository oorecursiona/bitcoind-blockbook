# bitcoind + Blockbook 部署

为 RGB++ indexer / gateway 自建 Bitcoin 数据源：一个 Bitcoin Core 全节点（`txindex=1`）加一个
[Blockbook](../blockbook)（本仓库同级目录下的 fork），用 Docker Compose 部署。

支持 `mainnet`、`testnet`（testnet3）、`testnet4`、`signet`，一套 `.env` 对应一个网络。

## 为什么用 Docker

结论：**用 Docker Compose**，原因：

- **和同项目其它服务一致**。`rgbpp-indexer`、`rgbpp-gateway` 都是 Compose + 一个 `scripts/*.sh`
  包装脚本，运维方式统一。
- **可复现**。Blockbook 依赖 RocksDB 9.10（静态链接）、ZeroMQ、jemalloc、特定 Go 版本，
  手工在服务器上编译容易出偏差；镜像里一次编好，换机器直接跑。bitcoind 用官方发布包并校验 sha256，
  版本与 Blockbook fork 的 `configs/coins/bitcoin*.json` 保持一致（31.1）。
- **多网络共存**。每个网络一个 Compose project、一套端口（沿用 Blockbook 端口登记表），互不干扰。

代价与注意点：

- 链数据用 **bind mount 到宿主机目录**（`DATA_DIR`），不放 Docker 卷，方便看容量、迁移、做快照。
- 在 Linux 上 Docker 的磁盘 IO 没有额外损耗；**不要在 macOS Docker Desktop 上跑正式同步**，
  文件系统虚拟化会慢一个量级，只适合开发验证。
- 两个服务都需要**优雅停机**：bitcoind 要刷 UTXO 缓存，Blockbook 的 RocksDB 在初始批量导入时被
  强杀会导致必须全量重建。Compose 里已设 `stop_grace_period`（10 分钟 / 5 分钟），
  **不要用 `docker kill` 或 `docker compose down -t 0`**。

Blockbook 官方的另一条路是 `make all-bitcoin_testnet4` 打 `.deb` 包 + systemd 运行（见
`../blockbook/docs/build.md`）。只在需要和上游运维方式完全一致时才考虑。

## 目录结构

```
docker-compose.yml     两个服务：bitcoind、blockbook
.env.example           配置模板（scripts/btc.sh init 会生成 .env）
bitcoind/              官方二进制镜像；entrypoint 按 .env 生成 bitcoin.conf
blockbook/             从 ../blockbook 源码多阶段构建；entrypoint 生成 blockchaincfg.json
scripts/btc.sh         运维脚本
```

## 服务器配置建议

### testnet4（推荐配置）

| 项目 | 最低 | 推荐 |
|---|---|---|
| CPU | 2 vCPU | **4 vCPU** |
| 内存 | 8 GB | **16 GB** |
| 磁盘 | 200 GB SSD | **500 GB NVMe / SSD**（≥3000 IOPS） |
| 带宽 | 50 Mbps | 100 Mbps 以上，流量不限或 ≥2 TB/月 |
| 系统 | Ubuntu 22.04 / 24.04 或 Debian 12，x86_64 或 arm64 |

容量说明：testnet4 自 2024 年启动后被大量刷交易，区块数据增长比预期快；bitcoind（含 `txindex`）
和 Blockbook 索引（含 `-extendedindex`）的体积大致在同一量级，两者合计目前在一两百 GB 范围内并持续增长。
**500 GB 是为 1~2 年增长留出的余量**；部署后用 `scripts/btc.sh status` 里的 `size_on_disk`、
`dbSize` 实测，按增长速度规划扩容。

内存说明：16 GB 时，bitcoind `dbcache=2000`（MiB）、Blockbook RocksDB 缓存 1 GiB，加上 Blockbook
初始同步时的工作内存和 mempool，留有充足余量。8 GB 机器建议把 `BITCOIND_DBCACHE` 降到 1000、
`BLOCKBOOK_WORKERS` 降到 4。

### AWS 具体型号（testnet4）

| 用途 | EC2 实例 | 规格 | 存储（EBS） | 说明 |
|---|---|---|---|---|
| **推荐** | **m7i.xlarge** | 4 vCPU / 16 GiB，x86_64 | **gp3 500 GiB** | 稳定性能，镜像直接构建，最省心 |
| 推荐（更省钱） | m7g.xlarge | 4 vCPU / 16 GiB，Graviton3 arm64 | gp3 500 GiB | 同规格价格更低；镜像需在 arm64 上构建（本仓库 Dockerfile 已支持 arm64） |
| 最低 | t3.large / t4g.large | 2 vCPU / 8 GiB，突发型 | gp3 300 GiB | 初始同步会持续吃满 CPU，突发积分很快耗尽；必须开 *Unlimited* 模式，或同步期间先用大机型、同步完再降配 |

EBS 建议：

- 用 **gp3**，不要用 gp2 / st1 / sc1（HDD 类型同步会极慢）。
- gp3 基线为 3000 IOPS / 125 MiB/s。**初始同步期间可临时调到 6000 IOPS / 250 MiB/s**，同步完成后再调回基线
  （EBS 支持在线修改，同一卷两次修改间隔至少 6 小时）。
- 数据盘单独挂载（例如 `/data`），`DATA_DIR=/data/btc-testnet4`；系统盘 30 GiB 即可。
- 开启 EBS 快照（Data Lifecycle Manager 每日快照），可以用快照快速复制出新节点，省去数天重新同步。

安全组：

| 端口 | 来源 | 用途 |
|---|---|---|
| 22 | 运维 IP | SSH |
| 48333 | 0.0.0.0/0（可选） | testnet4 P2P 入站；不开放则节点只做出站连接，也能正常同步 |
| 19129 | **不对外开放** | Blockbook API，默认只绑 127.0.0.1；对外请经反向代理 + TLS，或只对 indexer/gateway 所在安全组放行 |
| 18029 / 48329 / 19029 | 不对外开放 | RPC / ZMQ / Blockbook 内部端口，只绑 127.0.0.1 |

如果 indexer/gateway 部署在另一台机器，把 `.env` 中 `BLOCKBOOK_BIND=0.0.0.0`，并在安全组里只放行它们的私网 IP / 安全组。

### 其它网络（参考）

| 网络 | 推荐配置 | AWS | 磁盘 |
|---|---|---|---|
| signet | 2 vCPU / 8 GB | t3.large / m7i.large | gp3 200 GiB |
| testnet（testnet3） | 4 vCPU / 16 GB | m7i.xlarge | gp3 1 TiB |
| mainnet | 8 vCPU / 32 GB | m7i.2xlarge（或 r7i.2xlarge 加大内存） | gp3 2 TiB 起，≥6000 IOPS；或 i4i.2xlarge 本地 NVMe（实例存储停机即丢，需配合快照/备份） |

mainnet 的 bitcoind 数据（含 txindex）已接近 1 TB，Blockbook 索引同量级，2 TiB 只够短期使用，需要规划扩容。

## 部署步骤

### 1. 准备服务器

```bash
# Ubuntu / Debian：安装 Docker Engine 与 Compose 插件
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # 重新登录后生效

# 挂载数据盘（以 AWS NVMe 设备为例，先用 lsblk 确认设备名）
sudo mkfs.ext4 /dev/nvme1n1
sudo mkdir -p /data
echo '/dev/nvme1n1 /data ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
sudo mount -a
```

需要 Docker Compose ≥ 2.17（用到 `build.additional_contexts`），`docker compose version` 确认。

### 2. 获取代码

`blockbook` 源码需要和本仓库放在同级目录（或在 `.env` 里改 `BLOCKBOOK_SRC`）：

```
rgbpp-infra/
├── bitcoind-blockbook/   ← 本仓库
└── blockbook/            ← Blockbook fork
```

### 3. 初始化配置

```bash
scripts/btc.sh init testnet4
```

生成 `.env`（权限 600）：网络、随机 RPC 密码、按 Blockbook 端口表分配的端口、Blockbook 版本号。
然后按服务器修改：

```bash
# 必改：数据目录指向数据盘
sed -i 's|^DATA_DIR=.*|DATA_DIR=/data/btc-testnet4|' .env
```

可选：`BITCOIND_DBCACHE`、`BLOCKBOOK_WORKERS`（≈ vCPU 数）、`BLOCKBOOK_EXTERNAL_APIS=0`
（不访问 mempool.space / CoinGecko）。完整说明见 `.env.example`。

### 4. 构建镜像

```bash
scripts/btc.sh build
```

Blockbook 镜像第一次构建需要编译 RocksDB，约 10~30 分钟；之后只改 Blockbook 源码时会复用该层。

### 5. 启动

推荐先单独同步 bitcoind，追上链头后再启动 Blockbook——Blockbook 初始批量导入直接从 bitcoind 读块，
bitcoind 本身还在同步时两者会抢 IO，总时长更长。

```bash
scripts/btc.sh up-bitcoind
scripts/btc.sh status          # 看 blocks / headers / verificationprogress
```

`initialblockdownload` 变成 `false` 后：

```bash
scripts/btc.sh up
scripts/btc.sh logs blockbook -f
scripts/btc.sh status          # blockbook.inSync 变为 true 即完成
```

直接 `scripts/btc.sh up` 也可以：Blockbook 会等 bitcoind 健康检查通过后启动并边追边索引，只是更慢。

### 6. 验证

```bash
curl -s http://127.0.0.1:19129/api/ | jq .blockbook
curl -s http://127.0.0.1:19129/api/v2/block-index/0
```

浏览器访问 `http://127.0.0.1:19129/` 是 Blockbook 自带的区块浏览器（远程机器用 `ssh -L 19129:127.0.0.1:19129` 转发）。

## 接入 RGB++ indexer / gateway

在 indexer 的配置（`rgbpp-indexer/config/*.toml`）中：

```toml
[btc]
source = "blockbook"
base_url = "http://<blockbook 主机>:19129"
```

或用环境变量 `BTC_SOURCE=blockbook`、`BTC_BASE_URL=http://<主机>:19129`。gateway 同理，
建议和 indexer 指向同一个 Blockbook，避免两边看到的链状态不一致。

注意：

- **网络必须一致**。indexer 现有 `testnet.toml` 用的是 `mempool.space/testnet`（即 testnet3），
  如果 RGB++ 部署在 testnet3 上，这里要用 `init testnet`，而不是 testnet4。
- **保留 `-extendedindex`**（Bitcoin 各网络的 coin 配置默认开启）。它让 Blockbook 记录每个输出被哪笔交易花费，
  indexer 解析 spender 依赖这一点。这个参数只在首次同步时生效，中途开启需要 `reset-blockbook` 全量重建。
- 若 indexer 跑在同一台机器的另一个 Compose 项目里，容器内访问宿主机 127.0.0.1 不通，可以设
  `BLOCKBOOK_BIND=0.0.0.0` 并用宿主机私网 IP，或把两个项目接到同一个外部 Docker network。

## 日常运维

| 命令 | 作用 |
|---|---|
| `scripts/btc.sh status` | 两个服务的同步进度 |
| `scripts/btc.sh logs [bitcoind\|blockbook] [-f\|N]` | 查看日志 |
| `scripts/btc.sh cli getpeerinfo` | 在容器内执行 bitcoin-cli（cookie 认证，无需密码） |
| `scripts/btc.sh restart blockbook` | 重启单个服务 |
| `scripts/btc.sh down` | 停止，数据保留 |
| `scripts/btc.sh reset-blockbook` | 删除 Blockbook 索引并重建（bitcoind 不动） |
| `scripts/btc.sh destroy` | 删除全部链数据（不可恢复） |

监控：Blockbook 内部端口 `127.0.0.1:19029/metrics` 是 Prometheus 指标；`/` 是状态页。
设置 `BB_ADMIN_USER` / `BB_ADMIN_PASSWORD` 后可用 `/admin`。

### 升级

- **Blockbook**：更新 `../blockbook` 代码后执行 `scripts/btc.sh build blockbook && scripts/btc.sh up`
  （不要重跑 `init`，它会重置 RPC 密码；`.env` 里的 `BLOCKBOOK_VERSION`、`BLOCKBOOK_GIT_COMMIT` 只影响版本显示，可手动更新）。
  留意 fork 的 changelog 是否要求重建索引。
- **bitcoind**：同时修改 `bitcoind/Dockerfile` 里的 `BITCOIN_VERSION` 和两个 sha256（与 blockbook fork
  `configs/coins/bitcoin*.json` 保持一致），以及 `.env` 的 `BITCOIN_VERSION`，再 `build bitcoind && up`。

### 备份

链数据都可以从 P2P 网络重新同步，不需要常规备份；备份的价值在于**节省重新同步的时间**。
做法：`scripts/btc.sh down` 后对 `DATA_DIR` 打快照（EBS 快照 / LVM 快照 / rsync），完成后再 `up`。
不要在运行中直接复制 RocksDB 或 bitcoind 数据目录。

## 故障排查

- **bitcoind 一直 unhealthy**：重启后加载区块索引需要时间，`logs bitcoind` 看是否在 `Loading block index` /
  `Verifying blocks`；健康检查有 15 分钟启动宽限期。
- **Blockbook 报 RPC 连接失败**：确认 `.env` 的 `RPC_PASSWORD` 在两个服务启动后没被改过；改了需要
  `scripts/btc.sh up`（重建两个容器）而不是只 restart 其中一个。
- **Blockbook 收不到新块 / mempool 不更新**：ZMQ 走容器网络 `tcp://bitcoind:28332`，`logs blockbook` 搜 `zeromq`。
- **初始同步中断后 Blockbook 无法启动**：批量导入被中断的数据库不可修复，执行 `scripts/btc.sh reset-blockbook` 重建。
- **磁盘写满**：两个服务都会异常退出。扩容后（EBS 在线扩容 + `resize2fs`）再 `up`。
