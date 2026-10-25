# sPad++

用 [Scintilla](https://www.scintilla.org/) ＋ [Lexilla](https://www.scintilla.org/Lexilla.html)
當編輯引擎、Cocoa 外殼從零重寫的 **macOS 原生文字編輯器**。

**狀態：早期原型。** 能開檔、編輯、存檔，扛得住 500 MB 的文件，
功能列表如下，但還沒到「每天上班用」的完成度。

> **這不是 fork。** 本專案沒有使用 Notepad++ 的任何程式碼、二進位或資料檔。
> 與 Notepad++ 的關係只有「功能與操作習慣的致敬」，實作完全不同。
> 與 Notepad++ 專案、Don Ho、Scintilla 專案均無隸屬或背書關係。
>
> 註：GitHub 不允許 repo 名稱包含 `+`，所以網址是 `sPadPlusPlus`；
> 產品名稱與 App bundle 仍然是 **sPad++**。

![畫面截圖](docs/screenshot.png)

---

## 目前已實作

### 文件與分頁

- 分頁可拖曳排序、超出寬度可橫向捲動、未儲存會有圓點標記
- **雙擊分頁標題可直接在標籤上改名**（Safari 風格）：Enter 確認、Esc 取消、點別處也算確認
  - 未命名分頁：打完名字後跳「另存新檔」選資料夾
  - 已存檔分頁：直接改磁碟上的檔名（自動保留副檔名、偵測同名）
- 也可用 **檔案 → 重新命名…（⇧⌘R）**
- Session 還原：檔案路徑、游標位置、捲動位置、編碼、主題
- 編碼自動偵測與轉換：UTF-8 / UTF-16、Big5、GB18030、Shift-JIS、
  EUC-JP/KR/TW、windows-1252（使用 [uchardet](https://github.com/BYVoid/uchardet)）
- 換行格式：LF / CRLF / CR 偵測與轉換
- 無損存檔保護：目標編碼無法表示某些字元時會先警告，不會靜默替換成 `?`

### 拖放與檔案關聯

- **把檔案拖進編輯區即可開啟**（拖放時游標顯示 copy，放開後開新分頁）
- 關聯 **100 種純文字／程式碼副檔名**：`txt md srt ass vtt log csv json yaml ini sh py c cpp go rs ...`
- Finder／Dock／`open -a` 三種方式都會開成分頁（單一實例）

### 預覽（Markdown／JSON）

狀態列**正中央**有一顆切換鈕，只在支援的檔案類型出現：

| 檔案 | 原始碼 | 預覽 |
|---|---|---|
| `.md .markdown .mdown .mkd` | Scintilla 語法高亮 | **排版後的文章**（標題／粗斜體／清單／引言／程式碼區塊／分隔線／連結） |
| `.json .jsonc .json5` | 原始文字 | **格式化 + 上色**（key / string / number / bool 分色） |

JSON 解析失敗會顯示錯誤訊息與原文，不會白畫面。

### 搜尋

- 尋找／取代面板：即時符合筆數、全部符合項高亮
- 支援 C++11 正規表示式（`SCFIND_CXX11REGEX`）、全字拼寫、大小寫、循環搜尋
- 檔案中尋找：跑在背景佇列、可中途取消、結果表格點兩下直接跳到該行

### 介面語系

- 預設 **繁體中文（台灣）**，內建英文（`en`）
- 所有介面字串走 `NSLocalizedString`；字串表的 key 就是繁中原文，
  所以缺翻譯時會自動回退成中文
- 翻譯表由 `scripts/gen_strings.py` 產生（`macapp/Resources/*.lproj/Localizable.strings`），
  新增語言只要在腳本裡加一個 dict

### 主題

- **6 套內建主題**（我們自己設計，非取自 Notepad++）：
  **墨 Ink**、**夜藍 Midnight**、**終端機 Terminal**（深色）、
  **紙 Paper**、**霧 Mist**、**高對比 Contrast**（淺色／無障礙）
- **格式與 Notepad++ 的 `themes/*.xml` 相容** —— 直接把 NPP 的主題檔丟進
  `~/Library/Application Support/sPad++/themes/`，重新載入就能用
  （已用 NPP 官方 `Obsidian.xml` 實測通過）
- 選單：**顯示 → 主題**；選擇會記住

![六套內建主題](docs/themes.png)

### 編輯

- 127 個 Lexilla 語法解析器、深色／淺色主題
- 多游標（`⌘D` 加下一個相同、`⇧⌘L` 選取全部相同）
- 欄位（矩形）選取（`Alt` ＋ 拖曳）
- 自動縮排（`{` 之後縮排、`}` 自動退回）、括號配對高亮、選取單字全檔高亮
- 文字自動完成（`⌘Return`）、字級縮放（`⌘=` `⌘-` `⌘0`）
- 顯示空白字元／換行符號
- **書籤**：`⌘F2` 切換、`F2` 下一個、`⇧F2` 上一個（邊界會出現藍色標記）
- **標記全部符合**：`⇧⌘M` 把搜尋結果的每一行標上綠點、`⇧⌘K` 清除

### 尚未支援

外掛、使用者自訂語言（UDL）、文件地圖、函式列表、巨集、列印、分割視窗。

---

## 建置

需求：macOS 11 以上、Xcode Command Line Tools（`xcode-select --install`）。

```bash
git clone https://github.com/tommy1616/sPadPlusPlus.git
cd sPadPlusPlus/macapp
make          # 第一次會一併編譯 Lexilla（127 個 lexer，約 2 分鐘）
open "sPad++.app"
```

產出是 `macapp/sPad++.app`。全部用 clang 編成 arm64，
**沒有 Xcode project、沒有 xib、沒有 Swift**。

診斷用指令：

```bash
./"sPad++.app/Contents/MacOS/sPad++" --bench 檔案.txt   # 載入 / 跳行 / 搜尋耗時
./"sPad++.app/Contents/MacOS/sPad++" --snapshot 輸出.png # 把視窗渲染成 PNG
```

---

## 效能（Apple Silicon，arm64 原生）

| 檔案 | 行數 | 載入 | 跳到檔尾 | 全文掃描 |
|---|---|---|---|---|
| 100 MB | 896,219 | 約 90–180 ms | 約 1 ms | 約 210 ms |
| 500 MB | 5,698,783 | 約 820–2400 ms＊ | 約 1 ms | 約 1.4–2.3 秒 |

＊ 量測時機器負載偏高，最好的一次是 823 ms。
載入是一次 `SCI_ADDTEXT`；上色是增量的，與檔案大小無關。

檔案中尋找：616 個檔案、1182 筆符合、約 800 ms，
期間主執行緒最大延遲 **74 ms**（20 ms 心跳）—— 也就是 UI 沒有被卡住。

---

## 架構

```
macapp/main.mm          約 2,400 行：AppDelegate、分頁、搜尋面板、編碼、session
third_party/scintilla   編輯引擎（Cocoa 平台層：ScintillaView、PlatCocoa）
third_party/lexilla     127 個語法解析器
third_party/uchardet    編碼偵測
```

Notepad++ 的 Win32 層負責的東西——訊息迴圈、對話框、docking、session——
在這裡全部由 Cocoa 外殼接手。Scintilla 透過標準的 `SCI_*` 訊息介面驅動，
編輯核心本身沒有改動。

已知建置問題：Lexilla 的 `LexUser.cxx` 只能在 Windows 編譯，
所以排除它、改連結一個 `lmUserDefine` 的空實作（`macapp/lexer_stub.cxx`）。

---

## App 圖示

- 分層素材：`scripts/icon-layers/`（背景、卡片、程式碼、游標）
  → `scripts/gen_icon_layers.py` 合成滿版單一圖層
- `macapp/AppIcon.icon/`：macOS 26 的 **Icon Composer 格式**（`icon.json` + `Assets/`）
- `macapp/build-icons.sh`：有 Xcode 26 時用 `actool` 編成 `Assets.car`（滿版圖示）；
  沒有就退回舊式 `.icns`（會被 macOS 26 套上白色底座）

> **踩過的坑 1**：`.icon` 裡如果放多個 group，第二個之後會被系統當成「漂浮玻璃層」
> 而整片模糊掉。所以主視覺必須**壓成一張圖、只用一個 group**。
>
> **踩過的坑 2**：換完圖示一定要清快取，否則 Dock / Finder 會一直顯示舊圖：
>
> ```bash
> make refresh-icon
> ```
>
> 它會關掉 App、重註冊 LaunchServices、清掉 `com.apple.iconservices` 快取並重啟 Dock。

## 設成預設的文字開啟程式

App 已經把「文字類」宣告成 `LSHandlerRank = Default`（`public.data` 保持 `Alternate`，
所以不會搶走二進位檔），接下來只要讓系統記住就行。

**方法一：Finder（圖形介面）**

1. 對著任一個 `.txt` 按右鍵 → **取得資訊**
2. **打開方式** → 選 `sPad++` → 按 **全部更改…**

**方法二：命令列**

```bash
# 需要先裝 duti： brew install duti
duti -s com.tommy1616.spad public.plain-text all
duti -s com.tommy1616.spad net.daringfireball.markdown all
```

沒有 `duti` 的話，`scripts/set-default-app.m` 是一個 20 行的替代工具：

```bash
clang -framework Cocoa -framework UniformTypeIdentifiers -o setdef scripts/set-default-app.m
./setdef /Applications/sPad++.app public.plain-text
```

> 換掉 App 路徑（搬動、改名）後要重設一次；建議把 App 放到 `/Applications`。

## 已知問題與處理

- **關分頁時可能閃退（SIGBUS in `-[ScintillaView dealloc]`）**
  ScintillaView 在 dealloc 時會呼叫 `removeObserver:`，若此時它還是視窗的 first responder，
  AppKit 與 CoreFoundation 會二次存取已釋放的物件。處理方式：
  關分頁前先把 first responder 移開，並把 view 放進**回收池**重複使用，
  整個 session 不銷毀（`recycleView:`）。

## 授權

**GPL-3.0-or-later**，完整條文見 [LICENSE](LICENSE)，第三方元件見 [NOTICE](NOTICE)。

選 GPL 是刻意的：保留未來重用 Notepad++ 的 GPL 資料檔（主題、語言定義）
或程式碼的空間，也符合這類編輯器社群的期待。

第三方元件各自維持原有授權：
Scintilla／Lexilla 是寬鬆的 HPND；uchardet 是三選一授權，本專案採 GPL-2.0-or-later。

---

## 致謝

- [Scintilla](https://www.scintilla.org/) 與 [Lexilla](https://www.scintilla.org/Lexilla.html) — Neil Hodgson
- [uchardet](https://github.com/BYVoid/uchardet) — BYVoid 與貢獻者
- 功能與操作習慣的概念來源：[Notepad++](https://notepad-plus-plus.org/) — Don Ho
