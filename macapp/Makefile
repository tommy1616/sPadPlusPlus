# sPad++ — macOS 原生文字編輯器（以 Scintilla 為編輯引擎）
#
# 直接用 clang 編譯 Scintilla 核心 + Cocoa 平台層 + Lexilla（靜態庫），不使用 Xcode project。

APP      := sPad++
BUNDLE   := $(APP).app
SC       := ../third_party/scintilla
LX       := ../third_party/lexilla
UCH      := ../third_party/uchardet
BUILD    := build

CXX      := clang++
ARCH     := -arch arm64
WARN     := -w
CXXFLAGS := $(ARCH) -std=c++17 -O2 -DNDEBUG $(WARN) \
            -I$(SC)/include -I$(SC)/src -I$(SC)/cocoa -I$(LX)/include -I$(UCH)
OBJCFLAGS := -fobjc-arc
LDFLAGS  := $(ARCH) -framework Cocoa -framework QuartzCore -framework CoreText \
            -framework CoreGraphics -framework Foundation

CORE_SRC  := $(wildcard $(SC)/src/*.cxx)
COCOA_SRC := $(wildcard $(SC)/cocoa/*.mm)
CORE_OBJ  := $(patsubst $(SC)/src/%.cxx,$(BUILD)/core_%.o,$(CORE_SRC))
COCOA_OBJ := $(patsubst $(SC)/cocoa/%.mm,$(BUILD)/cocoa_%.o,$(COCOA_SRC))
MAIN_OBJ  := $(BUILD)/main.o
STUB_OBJ  := $(BUILD)/lexer_stub.o
UCH_SRC   := $(wildcard $(UCH)/*.cpp)
UCH_OBJ   := $(patsubst $(UCH)/%.cpp,$(BUILD)/uch_%.o,$(UCH_SRC))
OBJS      := $(CORE_OBJ) $(COCOA_OBJ) $(STUB_OBJ) $(UCH_OBJ) $(MAIN_OBJ)

LEXILLA_A := $(LX)/bin/liblexilla.a
BIN       := $(BUNDLE)/Contents/MacOS/$(APP)

.PHONY: all run clean check-lexilla icons deps

all: $(BIN)

deps: $(LEXILLA_A)

$(LEXILLA_A):
	@echo "== 編譯 Lexilla（127 個 lexer，只有第一次需要） =="
	@cd $(LX)/src && mkdir -p ../bin && \
	 LEXERS=$$(ls ../lexers/Lex*.cxx | xargs -n1 basename | grep -v '^LexUser.cxx$$' | tr '\n' ' ') && \
	 make -j8 LEXERS="$$LEXERS" ../bin/liblexilla.a
	@echo "完成：$(LEXILLA_A)"

check-lexilla:
	@test -f $(LEXILLA_A) || (echo "缺少 $(LEXILLA_A)；請先執行 make deps"; exit 1)

$(BUILD):
	@mkdir -p $(BUILD)

$(BUILD)/core_%.o: $(SC)/src/%.cxx | $(BUILD)
	@$(CXX) $(CXXFLAGS) -x c++ -c $< -o $@

$(BUILD)/cocoa_%.o: $(SC)/cocoa/%.mm | $(BUILD)
	@$(CXX) $(CXXFLAGS) -x objective-c++ $(OBJCFLAGS) -c $< -o $@

$(BUILD)/lexer_stub.o: lexer_stub.cxx | $(BUILD)
	@$(CXX) $(CXXFLAGS) -I$(LX)/lexlib -x c++ -c $< -o $@

$(BUILD)/uch_%.o: $(UCH)/%.cpp | $(BUILD)
	@$(CXX) $(CXXFLAGS) -x c++ -c $< -o $@

$(BUILD)/main.o: main.mm | $(BUILD)
	@$(CXX) $(CXXFLAGS) -x objective-c++ $(OBJCFLAGS) -c $< -o $@

$(BIN): $(OBJS) $(LEXILLA_A) $(wildcard Themes/*.xml) \
        $(wildcard Resources/*.lproj/Localizable.strings) $(wildcard AppIcon.icon/**) Info.plist
	@mkdir -p $(BUNDLE)/Contents/MacOS
	@mkdir -p $(BUNDLE)/Contents/Resources
	@cp Info.plist $(BUNDLE)/Contents/Info.plist
	@./build-icons.sh
	@cp AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@mkdir -p $(BUNDLE)/Contents/Resources/Themes
	@cp Themes/*.xml $(BUNDLE)/Contents/Resources/Themes/
	@mkdir -p $(BUNDLE)/Contents/Resources
	@cp -R Resources/*.lproj $(BUNDLE)/Contents/Resources/
	@if [ -f Assets.car ]; then cp Assets.car $(BUNDLE)/Contents/Resources/Assets.car; fi
	$(CXX) $(ARCH) -o $@ $(OBJS) $(LEXILLA_A) $(LDFLAGS)
	@echo "完成：$(BIN)"

run: all
	./$(BIN)

icons:
	@./build-icons.sh

clean:
	rm -rf $(BUILD) $(BUNDLE) AppIcon.iconset
