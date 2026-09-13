# Bing 每日壁纸

利用 GitHub Actions 每天自动抓取必应（Bing）当日壁纸，转成 **WebP** 后归档，**零服务器、零密钥配置**。

参考项目：[AiZeroToOne/BingWallpapers](https://github.com/AiZeroToOne/BingWallpapers)，在其基础上做了改动（见下文「与原项目的差异」）。

## 产出

| 文件 | 说明 |
| --- | --- |
| `wallpapers/YYYY/MM/YYYYMMDD.webp` | 按**年月**归档的历史壁纸，一天一张，永不覆盖 |
| `paper.webp`（仓库根目录） | **当日最新壁纸**，全分辨率，每天更新 |
| `lite.webp`（仓库根目录） | **当日最新壁纸的封面轻量版**，缩放 + 压缩 + 体积上限保护，适合博客封面/网页背景 |

实测数据（源图为 4K 的 3.4 MB JPG）：

| 文件 | 尺寸 | 体积 | 对比源图 |
| --- | --- | --- | --- |
| `paper.webp` / 归档 | 3840×2160 | **2.1 MB** | −38% |
| `lite.webp` | **1280×720** | **60–190 KB** | **−94% ~ −98%** |

`lite.webp` 默认 1280px 宽、q=72 编码，**并带有 200 KB 体积上限保护**：编码结果超标时会自动降档重试，保证输出永远是个小文件。

> **为什么上限是必要的**：必应图片的内容复杂度差异极大，同样参数下体积能差 5 倍以上。用 8 张真实壁纸实测（1280px / q72）：<br>
> 简洁风光图仅 55 KB，而密集航拍图高达 316 KB。仅靠降低质量参数压不下来——在 1280px 下把 q72 降到 q50 只省 19%，而宽度 1280→1024 能省 40%，所以降档策略是**优先降宽度、后降质量**。

其他特性：

- 源图默认拉取 **UHD 4K（3840×2160）**，失败自动回退 1920×1080
- WebP 编码使用 `-m 6` 最高压缩档，并保留 ICC 色彩描述文件（避免广色域图偏色）
- 时区统一按**北京时间**判定「当日」，文件名不会因 UTC 换算而差一天
- 图片日期以 Bing 接口返回的 `enddate` 为准，避免运行延迟导致归错档
- 内容未变化时不产生空提交（MD5 比对）
- 下载后校验 JPG 魔数（`FF D8 FF`），转换后校验 WebP 容器头（`RIFF....WEBP`）
- 更新后会**自动刷新 jsDelivr 的 CDN 缓存**，外链不必等缓存过期

## 目录结构

```
.
├── .github/workflows/bing-wallpaper.yml   # 定时工作流
├── scripts/fetch_bing_wallpaper.sh        # 抓取 + 转 WebP + 归档 + 同步 paper/lite
├── scripts/purge_jsdelivr.sh              # 刷新 jsDelivr 缓存
├── paper.webp                             # 当日最新壁纸（自动生成）
├── lite.webp                              # 当日轻量版（自动生成）
└── wallpapers/
    └── 2026/
        └── 09/
            ├── 20260911.webp
            └── 20260912.webp
```

> 源 JPG 只在临时目录中转，不会提交进仓库。

## jsDelivr 缓存自动刷新

jsDelivr 对文件有 CDN 缓存（实测响应头为 `s-maxage=43200`，即节点缓存 12 小时；浏览器端 `max-age=604800`，7 天）。不刷新的话，换了图之后外链仍会返回旧图。

工作流的最后一步会依次请求：

```
https://purge.jsdelivr.net/gh/Brandon-LIs/paper@refs/heads/main/paper.webp
https://purge.jsdelivr.net/gh/Brandon-LIs/paper@refs/heads/main/lite.webp
```

**这一步必须排在推送之后** —— jsDelivr 是回源到 GitHub 拉文件的，推送前刷新只会把旧内容重新缓存一遍。因此它的触发条件是 `changed == 'true'`，即确实有新图时才刷新。

成功时接口返回 `throttled: false` 且 `providers` 里列出已刷新的节点（实测为 `CF,FY`，即 Cloudflare 与 Fastly）。

### 关于限流

jsDelivr 对**同一路径**的刷新有频率限制，重复请求会返回：

```json
{ "status": "finished", "paths": { "...": { "throttled": true, "throttlingReset": 3466 } } }
```

`throttlingReset` 是剩余秒数（窗口约 1 小时）。这表示该路径**刚被刷新过、缓存本来就是新的**，属于正常情况，脚本只记警告、不会让工作流失败。本工作流每天只跑一次，正常不会遇到；只有手动重复触发时才会出现。

只有网络错误、非 200 响应、或 `status != finished` 才判定为失败（会重试 3 次后报错退出）。

脚本支持手动调用与自定义：

```bash
# 默认刷新 paper.webp 和 lite.webp
bash scripts/purge_jsdelivr.sh

# 指定仓库 / 引用 / 文件
bash scripts/purge_jsdelivr.sh Brandon-LIs/paper refs/heads/main paper.webp
```

环境变量：`JSDELIVR_UA`（请求 UA）、`PURGE_RETRIES`（重试次数，默认 3）、`PURGE_GRACE`（刷新前等待秒数，默认 5）。

## 部署步骤

1. **Fork 或新建仓库**，把本目录的全部文件推送到默认分支（`main`）。

2. **开启 Actions 写权限**：仓库 `Settings` → `Actions` → `General` → 底部 `Workflow permissions` 选择 **Read and write permissions**，保存。

   > 工作流只使用仓库自带的 `GITHUB_TOKEN`，不需要生成 SSH 密钥、不需要配置任何 Secret。

3. **验证**：进入 `Actions` 标签页 → 选择 `Bing Daily Wallpaper` → 点 `Run workflow` 手动跑一次。首次执行后根目录就会出现 `paper.webp` 和 `lite.webp`。

工作流内的 `push` 触发器监听了 `.github/workflows/**` 和 `scripts/**`，所以你改完脚本推上去它会自动跑一次，方便调试。

## 调体积 / 调画质

四个参数写在 `.github/workflows/bing-wallpaper.yml` 的 `env:` 里，改完推送即生效：

```yaml
- name: 抓取壁纸并转为 WebP
  env:
    WP_QUALITY: '80'        # paper.webp 的质量，越高越清晰、体积越大
    LITE_QUALITY: '72'      # lite.webp 的质量
    LITE_WIDTH: '1280'      # lite.webp 缩放宽度，0 表示不缩放
    LITE_MAX_BYTES: '200000'  # lite.webp 体积上限（字节），0 表示不限制
```

**关于 `LITE_WIDTH` 怎么选**：取决于封面在页面上实际显示的宽度。取「显示宽度的 1.0~1.5 倍」即可——若封面最大显示到 1200px，1280 足够；若是小卡片（≤700px），改成 1024 或 896 还能再省一半。

各档位在 8 张真实壁纸上的实测体积（4K 源图，q72）：

| `LITE_WIDTH` | 最小 | 平均 | 最大 | 适用 |
| --- | --- | --- | --- | --- |
| 1600 | 80 KB | 218 KB | 472 KB | 全宽横幅 |
| **1280（默认）** | **55 KB** | **143 KB** | **316 KB** | 博客封面（配合 200 KB 上限，实际最高 ≈194 KB） |
| 1024 | 35 KB | 85 KB | 191 KB | 卡片缩略图 |
| 800 | 23 KB | 51 KB | 114 KB | 小卡片 |

> 上表的「最大」是未启用上限时的裸体积。实际运行时 `LITE_MAX_BYTES` 会把超标的结果压回上限以内。

参考的组合（基于 4K 源图实测）：

| 用途 | 建议配置 | paper 体积 | lite 体积 |
| --- | --- | --- | --- |
| 默认（封面） | `80 / 72 / 1280 / 200000` | 2.1 MB | 60–190 KB |
| 极致轻量 | `80 / 70 / 1024 / 120000` | 2.1 MB | 35–115 KB |
| 全宽横幅 | `80 / 72 / 1600 / 350000` | 2.1 MB | 80–340 KB |

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
| `LITE_QUALITY` | `72` | lite 的 WebP 质量 |
| `LITE_WIDTH` | `1280` | lite 缩放宽度，`0` 表示不缩放 |
| `LITE_MAX_BYTES` | `200000` | lite 体积上限（字节），超出自动降档重试；`0` 表示不限制 |

## 与原项目的差异

1. **输出改为 WebP**：新增转换环节，归档文件、`paper.webp`、`lite.webp` 全部为 WebP 格式；源 JPG 仅作临时中转。
2. **新增根目录 `paper.webp` / `lite.webp`**：原项目只归档到 `wallpapers/`，现在额外在根目录维护两个固定文件名，可直接用稳定 URL 引用；`lite.webp` 缩放 + 压缩 + 体积上限保护，适合当作博客封面。
3. **修复时区问题**：原项目在 UTC 16:30 运行时用 `date +%Y` 取年月，实际拿到的是**前一天**的日期，归档路径会整体偏一天；现在固定 `TZ=Asia/Shanghai`，并以 Bing 的 `enddate` 为权威日期。
4. **免密钥推送 + 健壮性**：原项目需要配置 SSH 私钥（`SSH_PRIVATE_KEY`），现改用内置 `GITHUB_TOKEN`；同时补齐了图片完整性校验、幂等判断、空提交规避和推送失败重试。
5. **推送后自动刷新 jsDelivr 缓存**：原项目没有 CDN 环节；本版在推送成功后主动刷新 `paper.webp` / `lite.webp` 的 CDN 缓存，外链无需等待缓存过期。

## 常见问题

**Q：外链怎么用？**

```
https://raw.githubusercontent.com/<用户名>/<仓库>/main/paper.webp
https://raw.githubusercontent.com/<用户名>/<仓库>/main/lite.webp
```

配合 jsDelivr CDN 会更快：`https://cdn.jsdelivr.net/gh/<用户名>/<仓库>@main/paper.webp`

> CDN 缓存由工作流自动刷新（见上文），当日更新无需等待。`raw.githubusercontent.com` 基本实时但速度取决于网络。

**Q：旧版本留下的 `.jpg` 怎么办？**

工作流每次提交前会 `rm -f paper.jpg`，所以根目录的旧 `paper.jpg` 会在下次运行时自动从仓库移除。`wallpapers/` 里已归档的历史 `.jpg` 不会被删除，需要的话自行清理一次即可。

**Q：仓库体积会越来越大吗？**

WebP 的归档约 2.1 MB/张，一年约 780 MB（比原 JPG 方案省约 1/3）。若想进一步压缩，把 `WP_QUALITY` 降到 `75`，或把 `BING_RESOLUTION` 改为 `1920x1080`。

**Q：想只保留最新一张、不归档历史？**

把工作流提交步骤里的 `git add -A wallpapers paper.webp lite.webp` 中的 `wallpapers` 去掉即可。

**Q：外链还显示旧图？**

先确认工作流运行成功、且「刷新 jsDelivr 缓存」这一步没有报错。若是浏览器本地缓存（`max-age=604800`，7 天），强刷（`Cmd/Ctrl + Shift + R`）即可；CDN 节点缓存已由工作流主动刷新。

**Q：想换个 CDN？**

`scripts/purge_jsdelivr.sh` 里改成对应服务的刷新接口即可，工作流调用方式不变。

---

壁纸版权归 Microsoft Bing 及原作者所有，本仓库仅作抓取与转换归档。
