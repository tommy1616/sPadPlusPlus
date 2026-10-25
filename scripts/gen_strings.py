#!/usr/bin/env python3
"""產生 Localizable.strings（zh-Hant 為預設、en 為翻譯）。

字串表的 key 就是繁體中文原文，所以 zh-Hant 是 identity mapping；
新增語言只要在這裡加一個 dict。
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "..", "macapp", "main.mm")
OUT = os.path.join(HERE, "..", "macapp", "Resources")

EN = {
    "未命名": "Untitled",
    "尋找": "Find",
    "取代": "Replace",
    "檔案中尋找": "Find in Files",
    "尋找：": "Find:",
    "輸入要尋找的文字…": "Text to find…",
    "取代為：": "Replace with:",
    "留空表示刪除": "Leave empty to delete",
    "大小寫須相符": "Match case",
    "全字拼寫": "Whole word",
    "正規表示式": "Regular expression",
    "循環": "Wrap around",
    "上一個": "Previous",
    "下一個": "Next",
    "全部取代": "Replace All",
    "開始搜尋": "Search",
    "關閉": "Close",
    "資料夾：": "Folder:",
    "瀏覽…": "Choose…",
    "篩選：": "Filter:",
    "*.txt;*.md（分號分隔）": "*.txt;*.md (semicolon separated)",
    "位置": "Location",
    "內容": "Content",
    "「%@」有未儲存的變更。": "“%@” has unsaved changes.",
    "關閉前要儲存嗎？": "Save before closing?",
    "儲存": "Save",
    "不儲存": "Don’t Save",
    "取消": "Cancel",
    "就緒": "Ready",
    "關於 sPad++": "About sPad++",
    "隱藏 sPad++": "Hide sPad++",
    "結束 sPad++": "Quit sPad++",
    "檔案": "File",
    "新增分頁": "New Tab",
    "開啟…": "Open…",
    "關閉分頁": "Close Tab",
    "另存新檔…": "Save As…",
    "從磁碟重新載入": "Reload from Disk",
    "執行載入效能測試…": "Run Load Benchmark…",
    "編輯": "Edit",
    "復原": "Undo",
    "重做": "Redo",
    "剪下": "Cut",
    "複製": "Copy",
    "貼上": "Paste",
    "全選": "Select All",
    "尋找…": "Find…",
    "取代…": "Replace…",
    "檔案中尋找…": "Find in Files…",
    "找下一個": "Find Next",
    "找上一個": "Find Previous",
    "選取下一個相同": "Select Next Occurrence",
    "選取全部相同": "Select All Occurrences",
    "文字自動完成": "Word Completion",
    "切換書籤": "Toggle Bookmark",
    "下一個書籤": "Next Bookmark",
    "上一個書籤": "Previous Bookmark",
    "標記全部符合": "Mark All Matches",
    "清除所有標記": "Clear All Marks",
    "跳至行…": "Go to Line…",
    "顯示": "View",
    "主題": "Themes",
    "顯示空白字元": "Show Whitespace",
    "顯示換行符號": "Show Line Endings",
    "放大": "Zoom In",
    "縮小": "Zoom Out",
    "實際大小": "Actual Size",
    "換行格式": "Line Endings",
    "編碼": "Encoding",
    "無法開啟 %@": "Cannot open %@",
    "不支援 %@ 編碼": "%@ encoding is not supported",
    "有字元無法用 %@ 編碼表示": "Some characters cannot be represented in %@",
    "「以 UTF-8 儲存」可完整保留內容；「用 ? 取代」會永久破壞那些字元。":
        "“Save as UTF-8” keeps everything; “replace with ?” destroys those characters permanently.",
    "以 UTF-8 儲存": "Save as UTF-8",
    "用 ? 取代並儲存": "Replace with ? and Save",
    "儲存失敗": "Save failed",
    "%@   ·   %ld 行   ·   %@": "%@   ·   %ld lines   ·   %@",
    "%@   ·   %@   ·   行 %ld，欄 %ld   ·   %ld 字元選取   ·   載入 %.0f ms":
        "%@   ·   %@   ·   Ln %ld, Col %ld   ·   %ld selected   ·   loaded %.0f ms",
    "沒有符合的結果（或表示式無效）": "No matches (or invalid expression)",
    "沒有符合的結果": "No matches",
    "%ld 筆符合%@　·　目前第 %ld 筆": "%ld matches%@　·　current #%ld",
    "（已達上限，僅顯示前 4000 筆）": " (limit reached, first 4000 shown)",
    "找不到": "Not found",
    "%ld 筆符合　·　目前第 %ld 筆": "%ld matches　·　current #%ld",
    "已取代 %ld 筆（%.0f ms）": "Replaced %ld occurrence(s) (%.0f ms)",
    "已停止": "Stopped",
    "請先輸入要尋找的文字": "Enter text to find first",
    "資料夾不存在": "Folder does not exist",
    "正規表示式錯誤：%@": "Regular expression error: %@",
    "停止": "Stop",
    "搜尋中…": "Searching…",
    "搜尋中…  已掃描 %lu 檔，%lu 筆": "Searching…   %lu files, %lu matches",
    "%@ 在 %lu 個檔案中找到 %lu 筆（%.0f ms）%@": "%@ %lu matches in %lu files (%.0f ms)%@",
    "已停止 —": "Stopped —",
    "，已達上限": ", limit reached",
    "重新載入主題": "Reload Themes",
    "開啟主題資料夾…": "Open Themes Folder…",
    "已載入 %lu 個主題": "Loaded %lu themes",
    "已移除書籤": "Bookmark removed",
    "已加入書籤": "Bookmark added",
    "沒有書籤": "No bookmarks",
    "請先在尋找面板輸入文字": "Type something in the Find panel first",
    "已標記 %ld 行": "Marked %ld line(s)",
    "已清除標記": "Marks cleared",
    "重新命名檔案": "Rename File",
    "重新命名": "Rename",
    "同名檔案已存在": "A file with that name already exists",
    "無法重新命名": "Could not rename",
    "重新命名…": "Rename…",
    "預覽": "Preview",
    "原始碼": "Source",
}


def keys_from_source():
    s = open(MAIN, encoding="utf-8").read()
    out = []
    for m in re.finditer(r'T\(@"((?:[^"\\]|\\.)*)"\)', s):
        k = m.group(1)
        if k not in out:
            out.append(k)
    return out


def esc(v):
    return v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write(lang, mapping):
    d = os.path.join(OUT, lang + ".lproj")
    os.makedirs(d, exist_ok=True)
    lines = ['/* sPad++ %s 語系表（自動產生，請改 scripts/gen_strings.py） */' % lang, ""]
    for k in keys_from_source():
        v = mapping.get(k, k)
        lines.append('"%s" = "%s";' % (esc(k), esc(v)))
    open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("寫出", d)


def main():
    ks = keys_from_source()
    missing = [k for k in ks if k not in EN]
    if missing:
        print("⚠ 缺英文翻譯：")
        for k in missing:
            print("   ", k)
    write("zh-Hant", {k: k for k in ks})
    write("en", EN)


if __name__ == "__main__":
    main()
