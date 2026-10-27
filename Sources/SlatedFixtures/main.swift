import Foundation

@testable import SlatedCore

// Golden test vectors: runs SlatedCore on curated inputs and records what it returns (errors
// included) as JSON. The JavaScript port in linux/gnome-extension/lib/core is checked against these
// files by linux/tests/run.mjs, so both implementations stay in step.
//
//   swift run SlatedFixtures [output-dir]      (default: fixtures/)
//
// Output is byte-stable: sorted keys, fixed UUIDs and dates in the inputs, no timestamps. Random
// identifiers that Swift generates (bindings without an id) are replaced by "RANDOM-UUID".
// `scripts/check-fixtures.sh` regenerates into a temporary folder and fails if fixtures/ is stale.

setvbuf(stdout, nil, _IOLBF, 0)

// Template fixtures format dates in UTC so they don't depend on the machine's time zone.
NSTimeZone.default = TimeZone(identifier: "UTC")!

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "fixtures", isDirectory: true)

/// One fixture file: `sections` maps a section name to its list of cases; `extra` holds shared
/// definitions (screen setups, variable sets) that cases refer to by name.
struct FixtureFile {
  var name: String
  var description: String
  var sections: [String: [J]]
  var extra: [String: J] = [:]
  /// How many levels of each top-level value are spread over lines (default: one case per line for
  /// sections, two levels for shared definitions).
  var depth: [String: Int] = [:]

  var caseCount: Int { sections.values.reduce(0) { $0 + $1.count } }

  /// Individual expected results: a grouped case (one setup, window and settings with `results` for
  /// many operations) counts each of its results.
  var vectorCount: Int {
    sections.values.joined().reduce(0) { total, item in
      if case .object(let results)? = item["results"] { return total + results.count }
      return total + 1
    }
  }

  func rendered() -> String {
    var members = extra
    members["description"] = .string(description)
    members["generator"] = "swift run SlatedFixtures (Sources/SlatedFixtures); do not edit by hand"
    for (key, cases) in sections { members[key] = .array(cases) }
    let lines = members.keys.sorted().map { key in
      let expand = depth[key] ?? (sections[key] != nil ? 1 : 2)
      return "  " + J.quote(key) + ": " + members[key]!.rendered(expand: expand, indent: "  ")
    }
    return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
  }
}

let files: [FixtureFile] = [
  expressionFixtures(),
  tokenizerFixtures(),
  operationFixtures(),
  keyFixtures(),
  screenFixtures(),
  frameFixtures(),
  slateConfigFixtures(),
  configurationFixtures(),
  starterFixtures(),
  settingsFixtures(),
  hotstringFixtures(),
  automationFixtures(),
  clipboardFixtures(),
]

do {
  try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
  var counts: [String: J] = [:]
  var vectors: [String: J] = [:]
  for file in files {
    let url = outputDirectory.appendingPathComponent(file.name)
    try Data(file.rendered().utf8).write(to: url)
    counts[file.name] = .object(file.sections.mapValues { .int($0.count) })
    vectors[file.name] = .int(file.vectorCount)
    print("\(file.name): \(file.caseCount) cases, \(file.vectorCount) expected results")
  }
  let total = files.reduce(0) { $0 + $1.vectorCount }
  let manifest: J = [
    "description": "Golden vectors from SlatedCore (Swift) for the JavaScript port. Regenerate with `make fixtures`.",
    "generator": "swift run SlatedFixtures (Sources/SlatedFixtures); do not edit by hand",
    "files": .object(counts),
    "vectors": .object(vectors),
    "totalVectors": .int(total),
  ]
  try Data((manifest.rendered(expand: 3) + "\n").utf8).write(
    to: outputDirectory.appendingPathComponent("manifest.json"))
  print(
    "\(total) expected results (\(files.reduce(0) { $0 + $1.caseCount }) cases) in \(files.count) files → \(outputDirectory.path)"
  )
} catch {
  FileHandle.standardError.write(Data("SlatedFixtures: \(error)\n".utf8))
  exit(1)
}
