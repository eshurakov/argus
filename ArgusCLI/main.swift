import ArgumentParser

@main
struct ArgusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "argus",
        abstract: "Control the running Argus application.",
        discussion: "Phase 1 scaffold only. Socket-backed commands arrive in a later phase.",
        version: "argus 1.1.0"
    )

    func run() throws {
        print("Argus CLI scaffold. Use --help for available options.")
    }
}
