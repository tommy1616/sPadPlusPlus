// macapp/lexer_stub.cxx
// Lexilla 的 LexUser.cxx 是 Windows-only（吃 windows.h / RichEdit），
// 但 Lexilla.o 的 lexer 表仍然參照 &lmUserDefine。
// 這裡補一個空實作，讓靜態連結過得去（spike 用不到 "user" lexer）。

#include "Scintilla.h"
#include "ILexer.h"
#include "Sci_Position.h"
#include "SciLexer.h"
#include "LexerModule.h"

#ifndef SCLEX_USER
#define SCLEX_USER 83
#endif

namespace {

void LexUserStub(Sci_PositionU, Sci_Position, int, Lexilla::WordList *[], Lexilla::Accessor &)
{
	// intentionally empty
}

const char *const userDefineWordLists[] = { "0", nullptr };

} // namespace

extern const Lexilla::LexerModule lmUserDefine(SCLEX_USER, LexUserStub, "user", nullptr, userDefineWordLists);
