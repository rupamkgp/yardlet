import Foundation

extension CLIUpdateCenter {
    /// The app's CLI update center: the selected runtimes, the running tasks, real processes, and
    /// copies of earlier versions under `~/.yardlet/cli-previous`.
    static func live(model: AppModel) -> CLIUpdateCenter {
        CLIUpdateCenter(dependencies: Dependencies(
            runtimes: { [weak model] in
                guard let model else { return [:] }
                var runtimes: [HarnessKind: URL] = [:]
                for descriptor in model.runtimeSelections.connectedDescriptors {
                    runtimes[descriptor.id] = model.runtimeSelections.selectedURL(for: descriptor.id)
                }
                return runtimes
            },
            busyHarnesses: { [weak model] in Set(model?.activeLocalSessions.map(\.harness) ?? []) },
            runner: LiveCLICommandRunner(),
            verifier: CLIVerificationProbe(codexEnvironment: model.codexEnvironmentManager),
            overrides: .shared,
            defaults: .yardlet,
            previousVersionsDirectory: FileManager.default.homeDirectoryForCurrentUser
                .appending(path: YardletProduct.storageDirectoryName, directoryHint: .isDirectory)
                .appending(path: CLIRuntimeOverrides.copiesFolderName, directoryHint: .isDirectory),
            runtimeChanged: { [weak model] harness, _ in await model?.harnessRuntimeChanged(harness) }
        ))
    }
}
