import AppHarborCore

struct ManagerPathConfiguration {
    var homebrewExecutables: [String] = []
    var npmExecutables: [String] = []
    var npmNodeExecutables: [String] = []
    var pipxExecutables: [String] = []
    var pipxHomes: [String] = []
    var cargoExecutables: [String] = []
    var cargoRoots: [String] = []
}

@MainActor
enum CoreEngineFactory {
    static func make(scanRoots: [String], paths: ManagerPathConfiguration, store: any InstallationStoring) -> AppHarborCoreEngine {
        AppHarborCoreEngine(adapters: [
            AppBundleAdapter(explicitRoots: scanRoots),
            HomebrewAdapter(explicitExecutables: paths.homebrewExecutables),
            NPMAdapter(explicitExecutables: paths.npmExecutables, explicitNodeExecutables: paths.npmNodeExecutables),
            PipxAdapter(explicitExecutables: paths.pipxExecutables, explicitHomes: paths.pipxHomes),
            CargoAdapter(explicitExecutables: paths.cargoExecutables, explicitRoots: paths.cargoRoots)
        ], store: store)
    }
}
