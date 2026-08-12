import Darwin
import SwiftUI

@main
enum PowerLensEntryPoint {
    static func main() {
        if SystemAPIProbeCommand.isRequested() {
            exit(SystemAPIProbeCommand.run())
        }

        PowerLensApp.main()
    }
}
