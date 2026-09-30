# SimCrux Localization Guidelines

**Canonical source:** The suite-wide CJK house style is owned by the WaveCrux repo (`wavecrux/.claude/instructions.md`). This file is SimCrux's adapted copy: the Core Principles, Suite-Wide Terms, acronym/brand lists, Placeholder Rules, Formatting Rules, Language-Specific Rules, Prohibited Patterns, and button-length targets are kept in lockstep with the canonical file; only the app glossary is SimCrux-specific. On any conflict, the WaveCrux file wins for suite-wide entries.

## Core Principles

1. **Precision over politeness** – Users are EDA professionals. Technical accuracy trumps marketing fluff.
2. **Conciseness** – UI space is limited. Keep buttons short; tooltips can be longer.
3. **Consistency** – Same English term → same translation everywhere in a given language.
4. **Preserve placeholders** – Never break ICU MessageFormat syntax.

## SimCrux Glossary (Mandatory Mappings)

Standardized in the 2026-07-18 suite-wide translation audit; these are the post-sweep renderings actually shipped in the ARB files.

| English | zh-CN | ja | ko |
|---------|-------|-----|-----|
| testbench | 测试平台 | テストベンチ | 테스트벤치 |
| regression (run) | 回归 | リグレッション | 회귀 |
| regression comparison | 回归比较 | リグレッション比較 | 회귀 비교 |
| pass (test result) | 通过 | 成功 | 통과 |
| fail (test result) | 失败 | 失敗 | 실패 |
| vacuous pass | 空匹配通过 | 空虚成功 | 공허 성공 |
| cover hit | 覆盖命中 | カバレッジヒット | 커버 히트 |
| cancelled (test status) | 已取消 | キャンセル済み | 취소됨 |
| flaky (test) | 不稳定测试 | 不安定なテスト | 불안정 테스트 |
| trend | 趋势 | トレンド | 트렌드 |
| retention | 保留 | 保持 | 보존 |
| seed | 种子 | シード | 시드 |
| simulator | 仿真器 | シミュレーター | 시뮬레이터 |
| config (the project config file) | 配置 | 構成 | 구성 |
| duration | 耗时 | 実行時間 | 소요 시간 |
| heatmap | 热图 | ヒートマップ | 히트맵 |
| suite (test suite) | 套件 | スイート | 스위트 |
| statistics window (flaky/trend) | 窗口 | ウィンドウ | 구간 |
| search across projects | 跨项目搜索 | プロジェクト横断検索 | 프로젝트 간 검색 |
| log line | 行 | 行 | 줄 |
| row (table row) | 行 | 行 | 행 |
| PR annotation | PR 批注 | PR アノテーション | PR 어노테이션 |
| Appearance (settings section) | 外观 | 外観 | 외관 |
| plugin | 插件 | プラグイン | 플러그인 |
| detector | 检测器 | ディテクター | 감지기 |
| Forget (recent-project action) | 移除 | 履歴から削除 | 목록에서 제거 |

Notes:
- ja "config" is 構成, reserving 設定 for the Settings screen — the File menu item is 構成を開く… and every string pointing at it must match.
- zh 批注 is for PR review annotations; 注释 remains reserved for code comments (per the suite glossary).
- ja label-value summaries ("Pass: {count}") use ASCII colon + space (成功: {count}) — the dominant core style. zh uses full-width ：with no space.

## Suite-Wide Terms (identical in every Crux app)

These concepts appear in more than one Crux app (CXP, shared chrome, settings). Every app — core and Pro overlay — must use exactly these renderings. App-local glossaries may add terms but may never override this table.

| English | zh-CN | ja | ko |
|---------|-------|-----|-----|
| cross-probe / cross-probing | 交叉探测 | クロスプローブ | 교차 프로브 |
| Remote Control (settings section) | 远程控制 | リモートコントロール | 원격 제어 |
| waiver / waive | 豁免 | ウェイバー | 면제 |
| workspace | 工作区 | ワークスペース | 워크스페이스 |
| preset | 预设 | プリセット | 프리셋 |
| editor | 编辑器 | エディター | 에디터 |
| viewer | 查看器 | ビューアー | 뷰어 |
| open-core (edition name) | 开放核心版 | オープンコア | 오픈 코어 |
| command palette | 命令面板 | コマンドパレット | 명령 팔레트 |
| panel | 面板 | パネル | 패널 |
| pane | 窗格 | ペイン | 창 |
| custom (adjective) | 自定义 | カスタム | 사용자 정의 (never 사용자 지정) |
| clock (noun) | 时钟 | クロック | 클럭 (never 클록) |

Note: 开放核心版, never 开源核心版 — "open-core" names the free edition, not a licence, and must not read as "open-source core".

## Acronyms (Never Translate)

VCD, FST, GHW, LXT, LXT2, FSDB, PCAP, CSV, JSON, XML, YAML, HTML, SVG, PNG, RGB, LED, LCD, OLED, FSM, RTL, API, SDK, ABI, CLI, GUI, WASM, TCP, UDP, HTTP, JSON-RPC, CXP, WCP, JUnit, UVM, p50, p95, p99

**Protocol/Interface names (never translate):**
SPI, I2C, I²C, UART, AXI, AXI4, AXI4-Lite, APB, AHB, AHB-Lite, Wishbone, JTAG, MDIO, CAN, CAN-FD, USB, PCIe, Ethernet, MII, RMII, GMII, RGMII, AXIS, RISC-V, RV32, RV64, Cocotb, GTKWave, Synopsys

**Tools/commands (never translate):**
fsdb2vcd, vcd2fst, xml2stems, vermin, dlopen, LoadLibrary, make, cmake, cocotb

**Product / brand names (never translate):**
WaveCrux, NetCrux, LintCrux, SimCrux, EDACrux, Ferrite Engineering, Stage, Stage Pro, Rive, Yosys, Verible, Verilator, svlint, GHDL, Icarus Verilog, cocotb, FuseSoC, Vivado, Quartus

"Stage" is the WaveCrux Stage brand and stays in Latin script everywhere (never 舞台 / ステージ / 스테이지). Legacy translated occurrences are defects to sweep.

## Placeholder Rules (ICU MessageFormat)

All plural placeholders MUST include both `=1` and `other` cases:

Correct:
"{count, plural, =1{1 signal} other{{count} signals}}"

Incorrect (missing =1 case):
"{count, plural, other{{count} signals}}"

For Chinese, Japanese, Korean (no grammatical number), use:

zh-CN:
"{count, plural, =1{1个信号} other{{count}个信号}}"

ja:
"{count, plural, =1{1シグナル} other{{count}シグナル}}"

ko:
"{count, plural, =1{1개 신호} other{{count}개 신호}}"

## Formatting Rules

### Ellipsis (…)
- All languages: No space before … (U+2026)
- Use single character …, not three dots

### Units
- Use localized unit symbols where standard: ms, ns, μs, MB, GB, Hz, kHz, MHz, GHz, FPS
- For frequency: {freq} Hz, {freq} MHz (keep space before unit in all languages)

### Symbols
- Δ (delta) → keep as Δ
- f (frequency) → keep as f (lowercase)
- × (multiply) → use ×, not x or *

## Language-Specific Rules

### Chinese (zh-CN)
- Use Simplified Chinese only
- 跳变 = signal edge transition; 转换 = format conversion
- 注释 = comment (never 评论)
- 显示 = show/display; 隐藏 = hide
- 无法 = cannot/failed; 失败 = failed
- Prefer 4-character phrases where natural (节省空间)

### Japanese (ja)
- **signal = 信号, never シグナル** (resolves the old kanji-vs-katakana ambiguity; the glossary previously said シグナル, actual usage was majority 信号, and 信号 is what JP EDA documentation uses). Sweep legacy シグナル occurrences.
- **Long-vowel (ー) forms for -er/-or katakana loanwords** (generalizing the デコーダー rule): デコーダー、インスペクター、エディター、ビューアー (not ビューワー)、サーバー、フォルダー、ドライバー、ワイヤー、シミュレーター. Short forms are defects.
- Use デコーダー consistently (not デコーダ)
- 表示中の = "visible" (e.g., 表示中のトランジション)
- 履歴 = "recent files history" (shorter than 最近のファイル)
- できません = polite negative; 失敗 = failure
- Never use あなた; use passive or drop subject
- Use kanji for common terms, katakana for technical imports

### Korean (ko)
- Use 10진수 (with Arabic numeral) for decimal
- 토글 레이트 > 토글 속도 for "toggle rate"
- 글리치 지점 > 글리치 포인트 for "glitch points"
- No space before … (U+2026) – fix all instances
- Use subject-drop where natural
- Use native Korean words over Sino-Korean when shorter

## Prohibited Patterns (All Languages)

- Never translate version numbers (v0.1.0 stays as-is)
- Never translate placeholder variable names ({count}, {filename}, {reason})
- Never translate help/documentation URLs (docs.wavecrux.app)
- Never translate license names (MIT, BSD-3-Clause)
- Never translate company names (Ferrite Engineering)
- Never translate brand/trademark disclaimers except for localization (keep original company names)

## Button Label Length Targets

| Language | Max chars for primary button | Max chars for tooltip |
|----------|------------------------------|----------------------|
| zh-CN | 8 | unlimited |
| ja | 10 | unlimited |
| ko | 8 | unlimited |

Example shortening:
- "Generate & Open in New Tab" → zh: "生成并打开", ja: "生成して開く", ko: "생성 후 열기"
- "Remove from recent files" → zh: "移除", ja: "削除", ko: "제거" (tooltip explains)

## Quality Checklist

Before outputting any ARB translation:
- [ ] All plural placeholders have `=1` case
- [ ] Acronyms are untouched
- [ ] URLs unchanged
- [ ] No English leftover (except acronyms)
- [ ] Consistent with glossary
- [ ] Button labels reasonably short
