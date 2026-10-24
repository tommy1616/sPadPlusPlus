#!/usr/bin/env python3
"""從內建調色盤產生 Notepad++ 相容的主題 XML。

產出的檔案放在 macapp/Themes/，可以直接被 sPad++ 讀取，
也可以被 Notepad++ 讀取（同一份 schema）。
"""
import os
import xml.sax.saxutils as sx

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "macapp", "Themes")

# ---------------------------------------------------------------- 語意角色
# lexer 名稱 -> {styleID: 角色}
LEXERS = {
    "cpp": ({1: "comment", 2: "comment", 3: "comment", 15: "comment", 17: "comment", 24: "comment", 25: "comment",
             4: "number", 5: "keyword", 16: "type", 6: "string", 7: "string", 12: "string", 13: "string",
             20: "string", 21: "string", 22: "string", 23: "string", 14: "string", 8: "preproc", 9: "preproc",
             10: "operator", 11: "default", 19: "type"}, "C++"),
    "python": ({1: "comment", 12: "comment", 2: "number", 3: "string", 4: "string", 6: "string", 7: "string",
                13: "string", 16: "string", 17: "string", 18: "string", 19: "string", 5: "keyword",
                14: "keyword", 8: "type", 9: "func", 15: "preproc", 20: "preproc", 10: "operator", 11: "default"}, "Python"),
    "json": ({1: "number", 2: "string", 3: "string", 4: "keyword", 5: "string", 6: "comment", 7: "comment",
              8: "operator", 9: "string", 11: "keyword", 13: "error"}, "JSON"),
    "markdown": ({1: "default", 2: "keyword", 3: "keyword", 4: "keyword", 5: "keyword", 6: "func", 7: "func",
                  8: "func", 9: "func", 10: "func", 11: "func", 12: "preproc", 13: "keyword", 14: "keyword",
                  15: "comment", 16: "string", 17: "string", 18: "string", 19: "string"}, "Markdown"),
    "hypertext": ({1: "keyword", 2: "keyword", 3: "type", 4: "type", 5: "number", 6: "string", 7: "string",
                   8: "default", 9: "comment", 10: "preproc", 11: "keyword", 12: "preproc", 13: "preproc",
                   14: "keyword", 15: "preproc", 17: "string", 18: "operator", 19: "string"}, "HTML"),
    "bash": ({1: "error", 2: "comment", 3: "number", 4: "keyword", 5: "string", 6: "string", 7: "operator",
              8: "default", 9: "preproc", 10: "preproc", 11: "string", 12: "preproc", 13: "string"}, "Shell"),
    "sql": ({1: "comment", 2: "comment", 3: "comment", 13: "comment", 15: "comment", 4: "number",
             5: "keyword", 16: "type", 6: "string", 7: "string", 8: "preproc", 9: "preproc",
             10: "operator", 11: "default"}, "SQL"),
    "rust": ({1: "comment", 2: "comment", 3: "comment", 4: "comment", 5: "number", 6: "keyword",
              7: "type", 8: "type", 9: "type", 10: "type", 11: "type", 12: "type",
              13: "string", 14: "string", 15: "string", 16: "string", 17: "string"}, "Rust"),
    "props": ({1: "comment", 2: "func", 3: "operator", 4: "string", 5: "keyword"}, "Properties"),
    "makefile": ({1: "comment", 2: "preproc", 3: "default", 4: "operator", 5: "func", 9: "string"}, "Makefile"),
}

# ---------------------------------------------------------------- 內建主題（我們自己的設計）
THEMES = {
    "ink": {
        "name": "墨 Ink", "dark": True,
        "default": "D6D3CC", "bg": "1C1B19",
        "comment": "726D63", "keyword": "E0B060", "type": "8FB8D8", "func": "C8A0DC",
        "string": "A8C97F", "number": "D19A66", "operator": "C8C4BB",
        "preproc": "B08968", "error": "E06C75",
        "selection": "3A3226", "caret": "E0B060", "caretline": "242220",
        "linenum": "5C5850", "ws": "3A3630",
    },
    "midnight": {
        "name": "夜藍 Midnight", "dark": True,
        "default": "C8D3E8", "bg": "0F1729",
        "comment": "565F89", "keyword": "7AA2F7", "type": "2AC3DE", "func": "BB9AF7",
        "string": "9ECE6A", "number": "FF9E64", "operator": "89DDFF",
        "preproc": "E0AF68", "error": "F7768E",
        "selection": "283457", "caret": "7AA2F7", "caretline": "1A2337",
        "linenum": "3B4261", "ws": "2A3350",
    },
    "terminal": {
        "name": "終端機 Terminal", "dark": True,
        "default": "33FF66", "bg": "05080A",
        "comment": "1F7A33", "keyword": "7CFFA0", "type": "66FF99", "func": "CCFFCC",
        "string": "99FFCC", "number": "AAFF77", "operator": "33FF66",
        "preproc": "88FF88", "error": "FF5555",
        "selection": "0C3A18", "caret": "33FF66", "caretline": "071008",
        "linenum": "1F7A33", "ws": "0F2014",
    },
    "paper": {
        "name": "紙 Paper", "dark": False,
        "default": "2B2A27", "bg": "F7F1E3",
        "comment": "8C8577", "keyword": "8B4513", "type": "2C5F8A", "func": "7B4B94",
        "string": "2E7D32", "number": "B25E00", "operator": "4A4740",
        "preproc": "8B4513", "error": "C0392B",
        "selection": "E8DEC6", "caret": "8B4513", "caretline": "F1E9D8",
        "linenum": "B0A794", "ws": "D8CFBC",
    },
    "mist": {
        "name": "霧 Mist", "dark": False,
        "default": "2E3440", "bg": "F4F6F8",
        "comment": "95A0AD", "keyword": "5E81AC", "type": "8F6F9E", "func": "B48EAD",
        "string": "4F7A4F", "number": "B0723C", "operator": "4C566A",
        "preproc": "8F6F9E", "error": "BF616A",
        "selection": "DCE4EC", "caret": "5E81AC", "caretline": "EAEFF4",
        "linenum": "A8B3BF", "ws": "CBD4DE",
    },
    "contrast": {
        "name": "高對比 Contrast", "dark": True,
        "default": "FFFFFF", "bg": "000000",
        "comment": "C8C8C8", "keyword": "FFFF00", "type": "00FFFF", "func": "00FF88",
        "string": "00FF00", "number": "FF9900", "operator": "FFFFFF",
        "preproc": "FF66FF", "error": "FF3333",
        "selection": "004080", "caret": "FFFFFF", "caretline": "101010",
        "linenum": "A0A0A0", "ws": "404040",
    },
}

# fontStyle：1=粗體 2=斜體 3=粗斜體
ROLE_STYLE = {
    "comment": 2, "keyword": 1, "type": 0, "func": 0, "string": 0,
    "number": 0, "operator": 0, "preproc": 0, "error": 0, "default": 0,
}


def esc(v):
    return sx.escape(str(v), {'"': "&quot;"})


def gen(theme_id, t):
    L = []
    L.append('<?xml version="1.0" encoding="UTF-8" ?>')
    L.append("<!-- sPad++ 內建主題：%s -->" % esc(t["name"]))
    L.append("<!-- 格式與 Notepad++ 的 themes/*.xml 相容 -->")
    L.append("<NotepadPlus>")
    L.append("    <LexerStyles>")
    for lexer, (roles, desc) in LEXERS.items():
        L.append('        <LexerType name="%s" desc="%s" ext="">' % (lexer, esc(desc)))
        L.append('            <WordsStyle name="DEFAULT" styleID="0" fgColor="%s" bgColor="%s" '
                 'fontName="" fontStyle="0" nesting="0"/>' % (t["default"], t["bg"]))
        for sid in sorted(roles):
            role = roles[sid]
            fg = t.get(role, t["default"])
            L.append('            <WordsStyle name="%s_%d" styleID="%d" fgColor="%s" '
                     'fontName="" fontStyle="%d" nesting="0"/>'
                     % (role.upper(), sid, sid, fg, ROLE_STYLE.get(role, 0)))
        L.append("        </LexerType>")
    L.append("    </LexerStyles>")
    L.append("    <GlobalStyles>")
    L.append('        <WidgetStyle name="Default Style" styleID="0" fgColor="%s" bgColor="%s"/>'
             % (t["default"], t["bg"]))
    L.append('        <WidgetStyle name="Current line background colour" styleID="0" bgColor="%s"/>'
             % t["caretline"])
    L.append('        <WidgetStyle name="Selected text colour" styleID="0" bgColor="%s"/>'
             % t["selection"])
    L.append('        <WidgetStyle name="Caret colour" styleID="0" fgColor="%s"/>' % t["caret"])
    L.append('        <WidgetStyle name="Line number margin" styleID="33" fgColor="%s" bgColor="%s"/>'
             % (t["linenum"], t["bg"]))
    L.append('        <WidgetStyle name="White space symbol" styleID="0" fgColor="%s"/>' % t["ws"])
    L.append("    </GlobalStyles>")
    L.append("</NotepadPlus>")
    return "\n".join(L) + "\n"


def main():
    os.makedirs(OUT, exist_ok=True)
    for tid, t in THEMES.items():
        path = os.path.join(OUT, tid + ".xml")
        open(path, "w", encoding="utf-8").write(gen(tid, t))
        print("寫出", path)


if __name__ == "__main__":
    main()
