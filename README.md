# enteauth

Ente Auth 的单仓切片：只取 Ente 单仓里与 Auth 有关的部分，Photos、Locker 两个 App 与服务端不在此仓。

## 来源

- 上游：[ente/ente](https://github.com/ente/ente)，提交 `6b0003ecee71f3c771c07469f5a145a641f02c9a`（2026-11-12）
- Auth 版本：4.4.28+1007（`mobile/apps/auth/pubspec.yaml`）
- 许可证：AGPL-3.0，`LICENSE` 文件与上游一致

机器可读的来源记录见 `UPSTREAM.json`。

## 包含什么

目录布局与上游完全一致，相对路径依赖不用改：

- `mobile/apps/auth/`：Auth 的 Flutter 客户端（Android / iOS / Windows / macOS / Linux / Web）
- `mobile/packages/`：全部共享包（Auth 直接与间接依赖的都在内，另有少数共享包一并保留，避免改动 workspace 解析）
- `mobile/cargokit/`、`mobile/gradle/`：Flutter Rust 构建支持
- `web/apps/auth/`：Auth 的 Web 端
- `web/packages/`：全部共享包与 wasm 包（Auth 的 Web 构建要用到 `ente-new`，而它又依赖 `ente-gallery` 与 `ente-photos-wasm`，故全留）
- `rust/`：整个 Rust workspace（FRB 与 wasm 绑定共用同一 workspace 清单，拆开反而要改清单，未动）
- 根目录的 `LICENSE`、`.gitmodules`、`.gitignore`

## 排除什么

- `mobile/apps/photos/`、`mobile/apps/locker/` 及其插件
- 除 `auth` 外的全部 `web/apps/*`
- `desktop/`（Ente Photos 的 Electron 壳，与 Auth 无关）
- `server/`（Go 服务端，Auth 与 Photos 共用；同步请用官方服务，或去整仓自建）
- `cli/`、`android/`、`apple/`、`docs/`、`infra/`、`.github/`、`architecture/`、`web/e2e/`、`web/docs/`
- `mobile/pubspec.lock` 与 `web/package-lock.json`：两个锁文件引用了已排除的成员，带入会坏，首次构建时重新生成即可

## 与上游的差别

切片本身除本 README、`UPSTREAM.json`、`binary-files.txt`、`scripts/` 这几个新文件外，只改了一个文件：

- `mobile/pubspec.yaml`：workspace 成员列表去掉 `apps/locker`、`apps/photos` 与 8 个 Photos 插件，其余（共享包列表、`dependency_overrides`）原样保留

在此之上，本仓加了两项上游没有的本地功能（2026-11-12，代码里以 `Local addition (enteauth slice)` 注释标出）：

1. **WebDAV 同步（仅离线模式）**：设置 → 数据 → WebDAV 同步。整个离线库存成一个文件存到 WebDAV 服务器，文件用同步密码派生的密钥加密（与加密导出同一套信封），服务器上只有密文。按更新时间逐条合并，删除经墓碑传播，相册图标图片随库存一起同步。实现：`lib/services/webdav_sync_service.dart`、`lib/models/webdav_vault.dart`；离线库升级到 v2（`syncId` 列 + `deleted_entities` 墓碑表），旧库自动迁移。
2. **相册自选图标**：编辑项目时，图标下方可从相册/文件选任意图片当图标（自动缩到 512px 存 PNG）。图标引用存在项目数据里，随 WebDAV 同步走；没图片时回落到内置图标。实现：`lib/services/code_icon_store.dart`，`CodeDisplay.iconImageId` 字段。
3. **去掉官方登录与账号体系**：启动直进离线主页，不再有登录/注册/账号/订阅/恢复密钥/删账号界面；在线同步已停用，只保留 WebDAV 同步。被摘掉的页面与服务文件保留在树里（已无引用，构建时 tree-shaking 移出二进制）。注意：此前用 Ente 账号登录过的设备，其在线库数据不会显示，本仓没有在线→离线迁移。

其余文本文件与上游逐字节一致。

## 二进制文件（未入库，需恢复）

推送工具只支持 UTF-8 文本，280 个二进制文件（图片、字体、图标，共约 31.5 MiB）没有入库，清单与 SHA256 在 `binary-files.txt`。恢复方法（二选一）：

```sh
bash scripts/restore-binaries.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File scripts\restore-binaries.ps1
```

脚本从上游按提交哈希下载每个文件并校验 SHA256，已存在且哈希一致的会跳过。另有一个上游误入的 `mobile/apps/auth/macos/packaging/dmg/DS_Store`（macOS Finder 元数据）已直接剔除，不在清单里。

## simple-icons 子模块（需恢复）

Auth 的品牌图标来自子模块 `mobile/apps/auth/assets/simple-icons`（simple-icons 仓库，提交 `6dcfdc2f58f6150d7b097b5cab158d27413f6366`）。`.gitmodules` 已保留，但子模块指针（gitlink）无法经推送工具入库，恢复方法：

```sh
git clone https://github.com/simple-icons/simple-icons.git mobile/apps/auth/assets/simple-icons
git -C mobile/apps/auth/assets/simple-icons checkout 6dcfdc2f58f6150d7b097b5cab158d27413f6366
```

或用 `git submodule add` 重新登记后再 `git submodule update --init`。不恢复的话 Flutter 构建会在资源步骤报错。

## 构建

先完成上面两步恢复，再：

```sh
# Flutter 客户端（Android 示例）
cd mobile
flutter pub get
cd apps/auth
flutter build apk

# Web 端
cd web
npm install
npm run build:auth

# Rust 绑定检查
cd rust
cargo check -p ente-auth-frb -p ente-auth-wasm -p ente-prelogin-wasm
```

Flutter 与 Rust 构建未经本机验证（切片环境无 Flutter / Cargo 工具链），以官方文档为准。

## 跟随上游

本仓与上游无 fork 关系，不会自动同步。跟新版时按 `UPSTREAM.json` 里记录的切片口径，从上游新提交重新切片后覆盖即可。
