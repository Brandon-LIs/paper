# Bing 每日壁纸

利用 GitHub Actions 每天自动抓取必应（Bing）当日壁纸，转成 **WebP** 后归档，**零服务器、零密钥配置**。

参考项目：[AiZeroToOne/BingWallpapers](https://github.com/AiZeroToOne/BingWallpapers)，在其基础上做了改动（见下文「与原项目的差异」）。

## 产出

| 文件 | 说明 |
| --- | --- |
| `wallpapers/YYYY/MM/YYYYMMDD.webp` | 按**年月**归档的历史壁纸，一天一张，永不覆盖 |
| `paper.webp`（仓库根目录） | **当日最新壁纸**，全分辨率，每天更新 |
| `lite.webp`（仓库根目录） | **当日最新壁纸的轻量版**，缩放 + 更高压缩，适合网页背景/预览 |

实测数据（2026-09-12，源图为 4K 的 3.4 MB JPG）：

| 文件 | 尺寸 | 体积 | 对比源图 |
| --- | --- | --- | --- |
| `paper.webp` / 归档 | 3840×2160 | **2.1 MB** | −38% |
| `lite.webp` | 1920×1080 | **298 KB** | **−91%** |

`lite.webp` 不到 300 KB，用作网页背景可以做到近乎瞬时的加载。

其他特性：

- 源图默认拉取 **UHD 4K（3840×2160）**，失败自动回退 1920×1080
- WebP 编码使用 `-m 6` 最高压缩档，并保留 ICC 色彩描述文件（避免广色域图偏色）
- 时区统一按**北京时间**判定「当日」，文件名不会因 UTC 换算而差一天
- 图片日期以 Bing 接口返回的 `enddate` 为准，避免运行延迟导致归错档
- 内容未变化时不产生空提交（MD5 比对）
- 下载后校验 JPG 魔数（`FF D8 FF`），转换后校验 WebP 容器头（`RIFF....WEBP`）

## 目录结构

```
.
├── .github/workflows/bing-wallpaper.yml   # 定时工作流
├── scripts/fetch_bing_wallpaper.sh        # 抓取 + 转 WebP + 归档 + 同步 paper/lite
├── paper.webp                             # 当日最新壁纸（自动生成）
├── lite.webp                              # 当日轻量版（自动生成）
└── wallpapers/
    └── 2026/
        └── 09/
            ├── 20260911.webp
            └── 20260912.webp
```

> 源 JPG 只在临时目录中转，不会提交进仓库。

## 部署步骤

1. **Fork 或新建仓库**，把本目录的全部文件推送到默认分支（`main`）。

2. **开启 Actions 写权限**：仓库 `Settings` → `Actions` → `General` → 底部 `Workflow permissions` 选择 **Read and write permissions**，保存。

   > 工作流只使用仓库自带的 `GITHUB_TOKEN`，不需要生成 SSH 密钥、不需要配置任何 Secret。

3. **验证**：进入 `Actions` 标签页 → 选择 `Bing Daily Wallpaper` → 点 `Run workflow` 手动跑一次。首次执行后根目录就会出现 `paper.webp` 和 `lite.webp`。

工作流内的 `push` 触发器监听了 `.github/workflows/**` 和 `scripts/**`，所以你改完脚本推上去它会自动跑一次，方便调试。

## 调体积 / 调画质

三个参数写在 `.github/workflows/bing-wallpaper.yml` 的 `env:` 里，改完推送即生效：

```yaml
- name: 抓取壁纸并转为 WebP
  env:
    WP_QUALITY: '80'      # paper.webp 的质量，越高越清晰、体积越大
    LITE_QUALITY: '75'    # lite.webp 的质量
    LITE_WIDTH: '1920'    # lite.webp 缩放宽度，0 表示不缩放
```

参考的体积/画质组合（基于 4K 源图实测）：

| 用途 | 建议配置 | paper 体积 | lite 体积 |
| --- | --- | --- | --- |
| 默认（推荐） | `80 / 75 / 1920` | 2.1 MB | 298 KB |
| 极致轻量 | `75 / 70 / 1600` | 1.7 MB | **144 KB** |
| 高画质 | `90 / 80 / 2560` | 3.4 MB | 620 KB |

## 定时说明

```yaml
on:
  schedule:
    - cron: '30 16 * * *'   # UTC 16:30 = 北京时间次日 00:30
```

⚠️ **GitHub 的 `schedule` 只能写 UTC**，且高峰期定时任务可能有几分钟到几十分钟的延迟，属于平台行为，无法避免。本项目的日期取自 Bing 接口的 `enddate`，因此即使延迟执行也不会把壁纸归到错误的日期下。

如果需要改时间，换算公式：**北京时间 − 8 小时 = UTC**（若结果为负数则日期减一天）。

## 本地测试

依赖 `curl` + WebP 转换工具；JSON 解析优先 `jq`、没有则自动回退 `python3`。

```bash
# 安装转换工具
brew install webp          # macOS
sudo apt install webp      # Ubuntu / Debian

bash scripts/fetch_bing_wallpaper.sh
```

脚本会优先使用 `cwebp`（libwebp 官方工具，压缩率更好），找不到时回退 ImageMagick；两者都没有会直接报错并提示安装命令。执行完成后会就地更新 `paper.webp`、`lite.webp` 与 `wallpapers/`，重复运行不会重复写入。

可用的环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `BING_MKT` | `zh-CN` | 市场代码，决定取哪个区的当日图 |
| `BING_RESOLUTION` | `UHD` | 源图分辨率，可改为 `1920x1080` |
| `WALLPAPER_DIR` | `wallpapers` | 归档根目录 |
| `PAPER_FILE` | `paper.webp` | 全分辨率文件名 |
| `LITE_FILE` | `lite.webp` | 轻量版文件名 |
| `WP_QUALITY` | `80` | paper 的 WebP 质量 |
| `LITE_QUALITY` | `75` | lite 的 WebP 质量 |
| `LITE_WIDTH` | `1920` | lite 缩放宽度，`0` 表示不缩放 |

## 与原项目的差异

1. **输出改为 WebP**：新增转换环节，归档文件、`paper.webp`、`lite.webp` 全部为 WebP 格式；源 JPG 仅作临时中转。
2. **新增根目录 `paper.webp` / `lite.webp`**：原项目只归档到 `wallpapers/`，现在额外在根目录维护两个固定文件名，可直接用稳定 URL 引用；`lite.webp` 缩放 + 压缩，适合当作网页背景。
3. **修复时区问题**：原项目在 UTC 16:30 运行时用 `date +%Y` 取年月，实际拿到的是**前一天**的日期，归档路径会整体偏一天；现在固定 `TZ=Asia/Shanghai`，并以 Bing 的 `enddate` 为权威日期。
4. **免密钥推送 + 健壮性**：原项目需要配置 SSH 私钥（`SSH_PRIVATE_KEY`），现改用内置 `GITHUB_TOKEN`；同时补齐了图片完整性校验、幂等判断、空提交规避和推送失败重试。

## 常见问题

**Q：外链怎么用？**

```
https://raw.githubusercontent.com/<用户名>/<仓库>/main/paper.webp
https://raw.githubusercontent.com/<用户名>/<仓库>/main/lite.webp
```

配合 jsDelivr CDN 会更快：`https://cdn.jsdelivr.net/gh/<用户名>/<仓库>@main/paper.webp`

> 注意 CDN 有缓存，当日更新可能有延迟；`raw.githubusercontent.com` 基本实时但速度取决于网络。

**Q：旧版本留下的 `.jpg` 怎么办？**

工作流每次提交前会 `rm -f paper.jpg`，所以根目录的旧 `paper.jpg` 会在下次运行时自动从仓库移除。`wallpapers/` 里已归档的历史 `.jpg` 不会被删除，需要的话自行清理一次即可。

**Q：仓库体积会越来越大吗？**

WebP 的归档约 2.1 MB/张，一年约 780 MB（比原 JPG 方案省约 1/3）。若想进一步压缩，把 `WP_QUALITY` 降到 `75`，或把 `BING_RESOLUTION` 改为 `1920x1080`。

**Q：想只保留最新一张、不归档历史？**

把工作流里的 `git add -A wallpapers paper.webp lite.webp paper.jpg` 中的 `wallpapers` 去掉即可。

---

壁纸版权归 Microsoft Bing 及原作者所有，本仓库仅作抓取与转换归档。
