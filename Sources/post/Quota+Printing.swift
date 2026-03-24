import SwiftMail

extension Quota {
    func printDetails() {
        for resource in resources {
            if resource.resourceName.uppercased() == "STORAGE" {
                print("\(resource.resourceName): \(resource.usage) / \(resource.limit) KB")
            } else {
                print("\(resource.resourceName): \(resource.usage) / \(resource.limit)")
            }
        }
    }
}
