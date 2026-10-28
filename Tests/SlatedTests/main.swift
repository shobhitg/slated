import Foundation

// Line-buffer output so results printed before a crash aren't lost.
setvbuf(stdout, nil, _IOLBF, 0)

// Add new suites here.
let suites: [Suite] = [
  configurationTests,
  slateKeystrokeTests,
  numericEdgeTests,
  crossPlatformBugTests,
  automationModelTests,
  clipboardHistoryTests,
  repeatScheduleTests,
  automationOptionsTests,
  hotstringMatcherTests,
  hotstringTemplateTests,
  slateScriptTests,
  javaScriptCoreContractTests,
  starterTests,
  starterSlateJSTests,
  importerTests,
  slateDescriptionTests,
  expressionTests,
  slateSyntaxTests,
  slateConfigParserTests,
  frameCalculatorTests,
  screenResolverTests,
  uiActionTests,
  uiValidationTests,
  uiModelTests,
  uiRecipeTests,
  uiClipboardTests,
  uiClipboardSwitcherTests,
  uiAutomationTests,
  uiAutomationValidationTests,
  uiSymbolContractTests,
  islandSettingsTests,
  uiCheatSheetTests,
  uiIslandModelTests,
  uiCenteredTitleTests,
  hidRemapperTests,
  keyboardTapTests,
  pasteboardTests,
  blockedSettingsTests,
  logRedactionTests,
  macOSContractTests,
  uiHostingContractTests,
  uiGetStartedTests,
]

let filter = CommandLine.arguments.dropFirst().first
exit(run(suites, filter: filter) == 0 ? 0 : 1)
