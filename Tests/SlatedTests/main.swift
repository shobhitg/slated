import Foundation

// Add new suites here.
let suites: [Suite] = [
  configurationTests
]

let filter = CommandLine.arguments.dropFirst().first
exit(run(suites, filter: filter) == 0 ? 0 : 1)
